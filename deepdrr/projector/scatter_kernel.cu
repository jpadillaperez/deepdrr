/*
 * Based on Sisniega et al. (2015), "High-fidelity artifact correction for cone-beam CT imaging of the brain"
 */

#define ELECTRON_REST_ENERGY 510998.918f // [eV]
#define INV_ELECTRON_REST_ENERGY 1.956951306108245e-6f // [eV]^{-1}

/* Material IDs for the nominal segmentation */
#define NOM_SEG_AIR_ID ((char) 0)
#define NOM_SEG_SOFT_ID ((char) 1)
#define NOM_SEG_BONE_ID ((char) 2)

/* Nominal density values, [g/cm^3] */
#define NOM_DENSITY_AIR 0.0f
#define NOM_DENSITY_SOFT 1.0f
#define NOM_DENSITY_BONE 1.92f

/* Compton data constant */
#define MAX_NSHELLS 30

/* Mathematical constants -- credit to Wolfram Alpha */
#define PI_FLOAT  3.14159265358979323846f
#define PI_DOUBLE 3.14159265358979323846
#define TWO_PI_FLOAT  6.28318530717958647693f
#define TWO_PI_DOUBLE 6.28318530717958647693

#define INFTY 500000.0f // inspired by MC-GPU :)
#define NEG_INFTY -500000.0f

/* Useful macros */
#define MAX_VAL(a, b) (((a) > (b)) ? (a) : (b))
#define MIN_VAL(a, b) (((a) < (b)) ? (a) : (b))

extern "C" {
    typedef struct plane_surface {
        // plane vector (nx, ny, nz, d), where \vec{n} is the normal vector and d is the distance to the origin
        float nx, ny, nz, d;
        // 'surface origin': a point on the plane that is used as the reference point for the plane's basis vectors 
        float ori_x, ori_y, ori_z;
        // the two basis vectors
        float b1_x, b1_y, b1_z;
        float b2_x, b2_y, b2_z;
        // the bounds for the basis vector multipliers to stay within the surface's region on the plane
        float bound1_lo, bound1_hi;
        float bound2_lo, bound2_hi;
        // can we assume that the basis vectors orthogonal?
        int orthogonal;
    } plane_surface_t;

    typedef struct rng_seed {
        int x, y;
    } rng_seed_t;

    typedef struct rita {
        int n_gridpts;
        double x[n_gridpts];
        double y[n_gridpts];
        double a[n_gridpts];
        double b[n_gridpts];
    } rita_t;

    typedef struct compton_data {
        int nshells;
        float f[MAX_NSHELLS]; // number of electrons in each shell
        float ui[MAX_NSHELLS]; // ionization energy for each shell, in [eV]
        float jmc[MAX_NSHELLS]; // (J_{i,0} m_{e} c) for each shell i. Dimensionless.
    } compton_data_t;

    __global__ void initialization_stage(
        int detector_width, // size of detector in pixels 
        int detector_height,
        char *nominal_segmentation, // [0..2]-labeled segmentation obtained by thresholding: [-infty, -500, 300, infty]
        float sx, // x-coordinate of source in IJK
        float sy,
        float sz,
        float *rt_kinv, // (3, 3) array giving the image-to-world-ray transform.
        int n_bins, // the number of spectral bins
        float *spectrum_energies, // 1-D array -- size is the n_bins
        float *spectrum_cdf, // 1-D array -- cumulative density function over the energies
        int photon_count, // number of photons to simulate (emit from source)
        float E_abs, // the energy level below which photons are assumed to be absorbed
        float *deposited_energy // the output.  Size is [detector_width]x[detector_height]
    ) {
        // TODO: further develop the arguments
        return;
    }

    __device__ void get_scattered_dir(
        float *dx, // both input and output
        float *dy,
        float *dz,
        double cos_theta,
        double phi
    ) {
        // Since \theta is restricted to [0,\pi], sin_theta is restricted to [0,1]
        float cos_th  = (float)cos_theta;
        float sin_th  = (float)sqrt(1.0 - cos_theta * cos_theta);
        float cos_phi = (float)cos(phi);
        float sin_phi = (float)sin(phi);

        float tmp = sqrtf(1.f - (*dz) * (*dz));

        float x = *dx, y = *dy, z = *dz;

        *dx = x * cos_th + sin_th * (x * z * cos_phi - y * sin_phi) / tmp;
        *dy = y * cos_th + sin_th * (y * z * cos_phi - x * sin_phi) / tmp;
        *dz = z * cos_th - sin_th * tmp * cos_phi;

        float mag = ((*dx) * (*dx)) + ((*dy) * (*dy)) + ((*dz) * (*dz)); // actually magnitude^2

        if (fabs(mag - 1.0f) > 1.0e-14) {
            // Only do the computationally expensive normalization when necessary
            mag = sqrtf(mag);

            *dx /= mag;
            *dy /= mag;
            *dz /= mag;
        }
    }

    #define VOXEL_EPS      0.000015f // epsilon (small distance) that we use to ensure that 
    #define NEG_VOXEL_EPS -0.000015f // the particle fully inside a voxel. Value from MC-GPU
    __device__ void move_photon_to_volume(
        float *pos_x, // position of the photon.  Serves as both input and ouput
        float *pos_y,
        float *pos_z,
        float dx, // direction of photon travel
        float dy,
        float dz,
        int *hits_volume, // Boolean output.  Does the photon actually hit the volume?
        float gVolumeEdgeMinPointX, // bounds of the volume
        float gVolumeEdgeMinPointY,
        float gVolumeEdgeMinPointZ,
        float gVolumeEdgeMaxPointX,
        float gVolumeEdgeMaxPointY,
        float gVolumeEdgeMaxPointZ
    ) {
        /*
         * Strategy: calculate the which direction out of {x,y,z} needs to travel the most to get
         * to the volume.  This determines how far the photon must travel if it has any hope of 
         * reaching the volume.
         * Next, will need to do checks to ensure that the resulting position is inside of the volume.
         */
        float dist_x, dist_y, dist_z;
        /* Calculations for x-direction */
        if (dx > VOXEL_EPS) {
            if (*pos_x > gVolumeEdgeMinPointX) {
                // Photon inside or past volume
                dist_x = 0.0f;
            } else {
                // Add VOXEL_EPS to make super sure that the photon reaches the volume
                dist_x = VOXEL_EPS + (gVolumeEdgeMinPointX - *pos_x) / dx;
            }
        } else if (dx < NEG_VOXEL_EPS) {
            if (*pos_x < gVolumeEdgeMaxPointX) {
                dist_x = 0.0f;
            } else {
                // In order to ensure that dist_x is positive, we divide the negative 
                // quantity (gVolumeEdgeMaxPointX - *pos_x) by the negative quantity 'dx'.
                dist_x = VOXEL_EPS + (gVolumeEdgeMaxPointX - *pos_x) / dx;
            }
        } else {
            // No collision with an x-normal-plane possible
            dist_x = NEG_INFTY;
        }

        /* Calculations for y-direction */
        if (dy > VOXEL_EPS) {
            if (*pos_y > gVolumeEdgeMinPointY) {
                // Photon inside or past volume
                dist_y = 0.0f;
            } else {
                // Add VOXEL_EPS to make super sure that the photon reaches the volume
                dist_y = VOXEL_EPS + (gVolumeEdgeMinPointY - *pos_y) / dy;
            }
        } else if (dy < NEG_VOXEL_EPS) {
            if (*pos_y < gVolumeEdgeMaxPointY) {
                dist_y = 0.0f;
            } else {
                // In order to ensure that dist_y is positive, we divide the negative 
                // quantity (gVolumeEdgeMaxPointY - *pos_y) by the negative quantity 'dy'.
                dist_y = VOXEL_EPS + (gVolumeEdgeMaxPointY - *pos_y) / dy;
            }
        } else {
            // No collision with an y-normal-plane possible
            dist_y = NEG_INFTY;
        }

        /* Calculations for z-direction */
        if (dz > VOXEL_EPS) {
            if (*pos_z > gVolumeEdgeMinPointZ) {
                // Photon inside or past volume
                dist_z = 0.0f;
            } else {
                // Add VOXEL_EPS to make super sure that the photon reaches the volume
                dist_z = VOXEL_EPS + (gVolumeEdgeMinPointZ - *pos_z) / dz;
            }
        } else if (dz < NEG_VOXEL_EPS) {
            if (*pos_z < gVolumeEdgeMaxPointZ) {
                dist_z = 0.0f;
            } else {
                // In order to ensure that dist_z is positive, we divide the negative 
                // quantity (gVolumeEdgeMaxPointZ - *pos_z) by the negative quantity 'dz'.
                dist_z = VOXEL_EPS + (gVolumeEdgeMaxPointZ - *pos_z) / dz;
            }
        } else {
            // No collision with an y-normal-plane possible
            dist_z = NEG_INFTY;
        }

        /* 
         * Store the longest distance to a plane in dist_z.
         * If distance if zero: interpret as photon already in volume, or no
         * intersection is possible (for example, if the photon is moving away)
         */
        dist_z = MAX_VAL(dist_z, MAX_VAL(dist_x, dist_y));

        // Move the photon to the volume (yay! the whole purpose of this function!)
        *pos_x += dist_z * dx;
        *pos_y += dist_z * dy;
        *pos_z += dist_z * dz;

        /*
         * Final error checking. Check if the new position is outside the volume.
         * If so, move the particle back to original position and set the intersection
         * flag to false.
         */
        if ((*pos_x < gVolumeEdgeMinPointX) || (*pos_x > gVolumeEdgeMaxPointX) ||
                (*pos_y < gVolumeEdgeMinPointY) || (*pos_y > gVolumeEdgeMaxPointY) ||
                (*pos_z < gVolumeEdgeMinPointZ) || (*pos_z > gVolumeEdgeMaxPointZ) ) {
            *pos_x -= dist_z * dx;
            *pos_y -= dist_z * dy;
            *pos_z -= dist_z * dz;
            *hits_volume = 0;
        } else {
            *hits_volume = 1;
        }
    }

    __device__ void sample_initial_dir(
        float *dx,
        float *dy,
        float *dz,
        rng_seed_t *seed
    ) {
        // TODO: implement
        // Sampling explanation here: http://corysimon.github.io/articles/uniformdistn-on-sphere/
        double phi = TWO_PI_DOUBLE * ranecu_double(seed);
        double theta = acos(1.0 - 2.0 * ranecu_double(seed));

        double sin_theta = sin(theta);
        
        *dx = (float)(sin_theta * cos(phi));
        *dy = (float)(sin_theta * sin(phi));
        *dz = (float)(cos(theta));
    }

    __device__ float sample_initial_energy(
        const int n_bins,
        const float *spectrum_energies,
        const float *spectrum_cdf,
        rng_seed_t *seed
    ) {
        float threshold = ranecu(seed);

        // Binary search to find the interval [CDF(i), CDF(i+1)] that contains 'threshold'
        int lo_idx = 0; // inclusive
        int hi_idx = n_bins; // exclusive
        int i;
        while (lo_idx < hi_idx) {
            i = (lo_idx + hi_idx) / 2; 

            // Check if 'i' is the lower bound of the correct interval
            if (threshold < spectrum_cdf[i]) {
                // Need to check lower intervals
                hi_idx = i;
            } else if (threshold < spectrum_cdf[i+1]) {
                // Found the correct interval
                break;
            } else {
                // Need to check higher intervals
                lo_idx = i + 1;
            }
        }

        /* DEBUG STATEMENT
        if (spectrum_cdf[i] > threshold) {
            printf(
                "ERROR: sample_initial_energy identified too-high interval. threshold=%.10f, spectrum_cdf[i]=%.10f\n", 
                threshold, spectrum_cdf[i]
            );
        }
        if (spectrum_cdf[i+1] <= threshold) {
            printf(
                "ERROR: sample_initial_energy identified too-low interval. threshold=%.10f, spectrum_cdf[i+1]=%.10f\n", 
                threshold, spectrum_cdf[i+1]
            );
        }
        */

        // Final interpolation within the spectral bin
        float slope = (spectrum_energies[i+1] - spectrum_energies[i]) / (spectrum_cdf[i+1] - spectrum_cdf[i])

        return spectrum_energies[i] + (slope * (threshold - spectrum_cdf[i]));
    }

    __device__ double sample_rita(
        const rita_t *sampler,
        rng_seed_t *seed
    ) {
        double y = ranecu_double(seed);

        // Binary search to find the interval [y_i, y_{i+1}] that contains y
        int lo_idx = 0; // inclusive
        int hi_idx = sampler->n_gridpts; // exclusive
        int i;
        while (lo_idx < hi_idx) {
            i = (lo_idx + hi_idx) / 2;

            // Check if 'i' is the lower bound of the correct interval
            if (y < sampler->y[i]) {
                // Need to check lower intervals
                hi_idx = i;
            } else if (y < sampler->y[i+1]) {
                // Found correct interval
                break;
            } else {
                // Need to check higher intervals
                lo_idx = i + 1;
            }
        }

        /* DEBUG STATEMENT
        if (sampler->y[i] > y) {
            printf("ERROR: RITA identified too-high interval. y=%.10f, y[i]=%.10f\n", y, sampler->y[i]);
        }
        if (sampler->y[i+1] <= y) {
            printf("ERROR: RITA identified too-low interval. y=%.10f, y[i+1]=%.10f\n", y, sampler->y[i+1]);
        }
        */

        double nu = y - sampler->y[i];
        double delta_i = sampler->y[i+1] - sampler->y[i];

        double tmp = (delta_i * delta_i) + (sampler->a[i] * delta_i * nu) + (sampler->b[i] * nu * nu); // denominator
        tmp = (1.0 + sampler->a[i] + sampler->b[i]) * delta_i * nu / tmp; // numerator / denominator

        return sampler->x[i] + (tmp * (sampler->x[i+1] - sampler->x[i]));
    }

    __device__ double sample_Rayleigh(
        float energy,
        const rita_t *ff_sampler,
        rng_seed_t *seed
    ) {
        double kappa = ((double)energy) * (double)INV_ELECTRON_REST_ENERGY;
        // Sample a random value of x^2 from the distribution pi(x^2), restricted to the interval (0, x_{max}^2)
        double x_max2 = 424.66493476 * 4.0 * kappa * kappa;
        float x2;
        do {
            x2 = sample_rita(ff_sampler, seed);
        } while (x2 > x_max2);

        double cos_theta;
        do {
            // Set cos_theta
            cos_theta = 1.0 - (2.0 * x2 / x_max2);

            // Test cos_theta
            //double g = (1.0 + cos_theta * cos_theta) * 0.5;
            
            // Reject and re-sample if \xi > g
        } while (ranecu_double(seed) > ((1.0 + cos_theta * cos_theta) * 0.5));

        return cos_theta;
    }

    __device__ double sample_Compton(
        float *energy, // serves as both input and output
        const compton_data_t *compton_data,
        rng_seed_t *seed
    ) {
        float kappa = *energy * INV_ELECTRON_REST_ENERGY;
        float one_p2k = 1.f + 2.f * kappa;
        float tau_min = 1.f / one_p2k;

        float a_1 = logf(one_p2k);
        float a_1 = 2.f * kappa * (1.f * kappa) / (one_p2k * one_p2k);

        /* Sample cos_theta */

        // Compute S(E, \theta=\pi) here, since it does not depend on cos_theta
        float s_pi = 0.f;
        for (int shell = 0; shell < compton_data->nshells; shell++) {
            float tmp = compton_data->ui[shell];
            if (*energy > tmp) { // this serves as the Heaviside function
                float left_term = (*energy) * (*energy - tmp) * 2.f; // since (1 - \cos(\theta)) == 2
                float piomc = (left_term - ELECTRON_REST_ENERGY * tmp) / (ELECTRON_REST_ENERGY * sqrtf(left_term + left_term + tmp * tmp)); // PENELOPE p_{i,max} / (m_{e} c)

                tmp = compton_data->jmc[shell] * piomc; // this now contains the PENELOPE value: J_{i,0} * p_{i,max}
                if (piomc < 0) {
                    tmp = (1.f - tmp - tmp);
                } else {
                    tmp = (1.f + tmp + tmp);
                }
                tmp = 0.5f - (0.5f * tmp * tmp); // calculating exponent
                tmp = 0.5 * expf(tmp);
                if (piomc > 0) {
                    tmp = 1.f - tmp;
                }
                // 'tmp' now holds PENELOPE n_{i}(p_{i,max})

                s_pi += (compton_data->f[shell] * tmp); // Equivalent to: s_pi += f_{i} n_{i}(p_{i,max})
            }
        }

        double cos_theta;
        // local storage for the results of calculating n_{i}(p_{i,max})
        float n_pimax_vals[MAX_NSHELLS];
        float tau;
        double one_minus_cos;

        do {
            /* Sample tau */
            if (ranecu(seed) < (a1 / (a1 + a2))) {
                // i == 1
                tau = powf(tau_min, ranecu(seed));
            } else {
                // i == 2
                tau = sqrtf(1.f + (tau_min * tau_min - 1.f) * ranecu(seed));
                /*
                 * Explanation: PENELOPE uses the term \tau_{min}^2 + \xi * (1 - \tau_{min}^2)
                 *  == 1 - (1 - \tau_{min}^2) + \xi * (1 - \tau_{min}^2)
                 *  == 1 + [(1 - \tau_{min}^2) * (-1 + \xi)]
                 *  == 1 + [(\tau_{min}^2 - 1) * (1 - \xi)]
                 *  == 1 + (\tau_{min}^2 - 1) * \xi,
                 * since \xi is uniformly distributed on the interval [0,1].
                 */
            }
            one_minus_cos = (1.0 - (double)tau) / ((double)kappa * (double)tau);

            float s_theta = 0.0f;
            for (int shell = 0; shell < compton_data->nshells; shell++) {
                float tmp = compton_data->ui[shell];
                if (*energy > tmp) { // this serves as the Heaviside function
                    float left_term = (*energy) * (*energy - tmp) * ((float)one_minus_cos);
                    float piomc = (left_term - ELECTRON_REST_ENERGY * tmp) / (ELECTRON_REST_ENERGY * sqrtf(left_term + left_term + tmp * tmp)); // PENELOPE p_{i,max} / (m_{e} c)

                    tmp = compton_data->jmc[shell] * piomc; // this now contains the PENELOPE value: J_{i,0} * p_{i,max}
                    if (piomc < 0) {
                        tmp = (1.f - tmp - tmp);
                    } else {
                        tmp = (1.f + tmp + tmp);
                    }
                    tmp = 0.5f - (0.5f * tmp * tmp); // calculating exponent
                    tmp = 0.5 * expf(tmp);
                    if (piomc > 0) {
                        tmp = 1.f - tmp;
                    }
                    // 'tmp' now holds PENELOPE n_{i}(p_{i,max})

                    s_pi += (compton_data->f[shell] * tmp); // Equivalent to: s_pi += f_{i} n_{i}(p_{i,max})
                    n_pimax_vals[shell] = tmp;
                }
            }
            
            // Compute the term of T(cos_theta) that does not involve S(E, \theta)
            float T_tau_term = kappa * kappa * tau * (1.f + tau * tau); // the denominator
            T_tau_term = (T_tau_term - (1.f - tau) * (one_p2k * tau - 1.f)) / T_tau_term; // the whole expression

            // Reject and re-sample if \xi > T(cos_theta)
            // Thus, reject and re-sample if (\xi * S(\theta=\pi)) > (T_tau_term * S(\theta))
        } while ((ranecu(seed) * s_pi) > (T_tau_term * s_theta));
        
        // cos_theta is set by now
        float cos_theta = 1.f - one_minus_cos;

        /* Choose the active shell */
        float pzomc; // "P_Z Over M_{e} C" == p_z / (m_{e} c)

        do {
            /*
             * Steps:
             *  1. Choose a threshold value in range [0, s_theta]
             *  2. Accumulate the partial sum of f_{i} \Theta(E - U_i) n_{i}(p_{i,max}) over the electron shells
             *  3. Once the partial sum reaches the threshold value, we 'return' the most recently considered 
             *      shell. In this manner, we select the active electron shell with relative probability equal 
             *      to f_{i} \Theta(E - U_i) n_{i}(p_{i,max}).
             *  4. Calculate a random value of p_z
             *  5. Reject p_z and start over if p_z < -1 * m_{e} * c
             *  6. Calculate F_{max} and F_{p_z} and reject appropriately
             */
            float threshold = ranecu(seed) * s_theta;
            float accumulator = 0.0f;
            int shell;
            for (shell = 0; shell < compton_data->nshells - 1; shell++) {
                /*
                 * End condition makes it such that if the first (nshells-1) shells don't reach threshold,
                 * the loop will automatically set active_shell to the last shell number
                 */
                accumulator += compton_data->f[shell] * n_pimax_vals[shell];
                if (accumulator >= threshold) {
                    break;
                }
            }

            two_A = ranecu(seed) * (2.f * n_pimax_vals[shell]);
            if (two_A < 1) {
                pzomc = 0.5f - sqrtf(0.25f - 0.5f * logf(two_A));
            } else {
                pzomc = sqrtf(0.25f - 0.5f * logf(2.f - two_A)) - 0.5f;
            }
            pzomc = pzomc / compton_data->jmc[shell];

            if (pzomc < -1.f) {
                // Erroneous (physically impossible) value obtained due to numerical errors. Re-sample
                continue;
            }

            // Calculate F(p_z) from PENELOPE-2006
            float tmp = 1.f + (tau * tau) - (2.f * tau * cos_theta); // tmp = (\beta)^2, where \beta := (c q_{C}) / E
            tmp = sqrtf(tmp) * (1.f + tau * (tau - cos_theta) / tmp);
            float F_p_z = 1.f + (tmp * pzomc);
            float F_max = 1.f + (tmp * 0.2f);
            if (pzomc < 0) {
                F_max = -1.f * F_max;
            }
            // TODO: refactor the above calculation so the comparison btwn F_max and F_p_z does not use division operations

            // Accept if (\xi * F_max) < F_p_z
            // Thus, reject and re-sample if (\xi * F_max) >= F_p_z
        } while ((ranecu(seed) * F_max) >= F_p_z);

        // pzomc is now set. Calculate E_ration = E_prime / E
        float t = pzomc * pzomc;
        float term_tau = 1.f - t * tau * tau;
        float term_cos = 1.f - t * tau * ((float)cos_theta);

        float E_ratio = sqrtf(term_cos * term_cos - term_tau * (1.f - t));
        if (pzomc < 0) {
            E_ratio = -1.f * E_ratio;
        }
        E_ratio = tau * (term_cos + E_ratio) / term_tau;

        *energy = E_ratio * (*energy);
        return cos_theta;
    }

    inline float ranecu(rng_seed_t *seed) {
        // Implementation from PENELOPE-2006 section 1.2
        int i = (int)(seed->x / 53668); // "i1"
        seed->x = 40014 * (seed->x - (i * 53668)) - (i * 12211);
        if (seed->x < 0) {
            seed->x = seed->x + 2147483563;
        }
        
        // no longer need "i1", so variable 'i' refers to "i2"
        i = (int)(seed->y / 52774);
        seed->y = 40692 * (seed->y - (i * 52774)) - (i * 3791);
        if (seed->y < 0) {
            seed->y = seed->y + 2147483399;
        }
        
        // no longer need "i2", so variable 'i' refers to "iz"
        i = seed->x - seed->y;
        if (i < 1) {
            i = i + 2147483562;
        }

        // double uscale = 1.0 / (2.147483563e9);
        // uscale is approx. equal to 4.65661305739e-10
        return ((float)i) * 4.65661305739e-10f;
    }

    inline double ranecu_double(rng_seed_t *seed) {
        // basically the same as ranecu(...), but converting to double at the end
        // Implementation from PENELOPE-2006 section 1.2
        int i = (int)(seed->x / 53668); // "i1"
        seed->x = 40014 * (seed->x - (i * 53668)) - (i * 12211);
        if (seed->x < 0) {
            seed->x = seed->x + 2147483563;
        }
        
        // no longer need "i1", so variable 'i' refers to "i2"
        i = (int)(seed->y / 52774);
        seed->y = 40692 * (seed->y - (i * 52774)) - (i * 3791);
        if (seed->y < 0) {
            seed->y = seed->y + 2147483399;
        }
        
        // no longer need "i2", so variable 'i' refers to "iz"
        i = seed->x - seed->y;
        if (i < 1) {
            i = i + 2147483562;
        }

        // double uscale = 1.0 / (2.147483563e9);
        // uscale is approx. equal to 4.6566130573917692e-10
        return ((double)i) * 4.6566130573917692e-10;
    }
}