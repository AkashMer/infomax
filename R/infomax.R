#' Run Infomax Independent Component Analysis
#'
#' Run Infomax or extended-Infomax on a matrix of data. Uses a mini-batch stochastic
#' gradient descent algorithm. The matrix can be prewhitened in several ways. The default is to perform
#' sphering using the inverse of the square root of the covariance matrix of the
#' original data, the method used by the 'EEGLAB' and 'MNE-Python' toolboxes in
#' other languages. Whitening methods implemented in the package `whitening` are
#' `PCA`, `ZCA`, `ZCA-cor`, and `PCA-cor`. Please see the `whitening` package
#' for further information on their implementation of these methods.
#'
#' @param x matrix of data; features in columns, samples in rows.
#' @param centre Mean-centre columns before running the algorithm. Defaults to
#'   TRUE.
#' @param pca Apply PCA decomposition. Accepts any value between 0 and
#' 1(exclusive), or an integer/whole number indicating the number of principal
#' components to be passed for ICA decomposition.
#' Values between 0 and 1 imply the percentage of variance explained by the
#' selected components.
#' Defaults to `NULL` which will result in all components being selected
#' @param anneal Annealing rate at which learning rate reduced.
#' @param annealdeg Angle at which learning rate reduced.
#' @param tol Tolerance for convergence of ICA. Defaults to 1e-07.
#' @param lrate Initial learning rate. NULL
#' @param blocksize Size of blocks of data used for learning.
#' @param kurtsize Size of blocks for kurtosis checking. Defaults to 6000 or
#'   length of data, whichever is smaller.
#' @param maxiter Maximum number of iterations. Defaults to 200.
#' @param extended Run extended-Infomax. Defaults to TRUE.
#' @param whiten Whitening method to use. See notes on usage.
#' @param random_seed Value to be passed to `set.seed()`. Defaults to NULL
#' @param verbose Print informative messages for each update of the algorithm.
#' @author Matt Craddock \email{matt@@mattcraddock.com}
#' @examples
#' time_x <- seq(0, 1, by = 1/256)
#' source_a <- sin(2 * pi * 5 * time_x)
#' source_b <- sin(2 * pi * 10 * time_x)
#' plot(time_x, source_a, type = "l")
#' plot(time_x, source_b, type = "l")
#' plot(time_x, source_a + 2 * source_b, type = "l")
#' plot(time_x, source_a * 3.4 + 1.5 * source_b, type = "l")
#' mixed_data <- matrix(NA,
#'     nrow = length(time_x),
#'     ncol = 2)
#' mixed_data[, 1] <- source_a + 2 * source_b
#' mixed_data[, 2] <- source_a * 3.4 + 1.5 * source_b
#' dat_out <- run_infomax(mixed_data, whiten = "PCA")
#' plot(time_x, dat_out$S[, 1],
#'     type = "l")
#' plot(time_x,
#'      dat_out$S[, 2],
#'      type = "l")
#' @references * Bell, A.J., & Sejnowski, T.J. (1995). An
#' information-maximization approach to blind separation and blind
#' deconvolution. *Neural Computation, 7,* 1129-159
#' * Makeig, S., Bell, A.J., Jung, T-P and Sejnowski, T.J., "Independent component analysis of
#' electroencephalographic data,"  In: D. Touretzky, M. Mozer and M. Hasselmo
#' (Eds). Advances in Neural  Information Processing Systems 8:145-151, MIT
#' Press, Cambridge, MA (1996).
#' @return A list containing:
#' * **S**:  Matrix of source estimates
#' * **M**:  Estimated mixing matrix
#' * **W**:  Estimated unmixing matrix
#' * **iter**: Number of iterations completed
#' @export
run_infomax <- function(x,
                        centre = TRUE,
                        pca = NULL,
                        anneal = .98,
                        annealdeg = 60,
                        tol = 1e-7,
                        lrate = NULL,
                        blocksize = NULL,
                        kurtsize = 6000,
                        maxiter = 200,
                        extended = TRUE,
                        whiten = c("sqrtm",
                                   "ZCA",
                                   "PCA",
                                   "ZCA-cor",
                                   "PCA-cor",
                                   "none"),
                        random_seed = NULL,
                        verbose = TRUE) {

  # Set the RNG seed
  if(!is.null(random_seed)) {
    set.seed(random_seed)
  }

  x <- as.matrix(x)
  whiten <- match.arg(whiten,
                      c("sqrtm",
                        "ZCA",
                        "PCA",
                        "ZCA-cor",
                        "PCA-cor",
                        "none"))

  if (is.null(pca)) {
    if (Matrix::rankMatrix(x) < ncol(x)) {
      stop("Matrix is not full rank.")
    }
  }

  # heuristic from EEGLAB; mne uses floor(sqrt(n_samps / 3))
  if (is.null(blocksize)) {
    blocksize <-
      ceiling(min(5 * log(nrow(x)),
                  0.3 * nrow(x)))
  }

  # # 1. remove column means
  if (centre) {
   x <- scale(x, scale = FALSE)
   if (verbose) {
     message("Removing column means...")
   }
  }

  # 2. perform pca if necessary
  if (!is.null(pca)) {

    # Run PCA decomposition
    pca_decomp <- prcomp(x)

    # Find the cumulative variance explained by each component
    pca_comp_cum_var_explained <- summary(pca_decomp)$importance[3,]

    # Check if number of components requested is not 0/1
    if(pca == 0 | pca == 1) {
      stop("Number of PCA components(pca) cannot be 0 or 1")
    }

    # Get the number of components which explain the requested variance
    # cumulatively
    if(pca > 0 & pca < 1) {
      ncomp <- max(which(
        pca_comp_cum_var_explained <= pca
      ))
      ncomp <- ncomp + 1
    } else {
      ncomp <- pca
    }
    message("Reducing data to ", ncomp,
            " dimensions using PCA.")

    # Apply the rotation to the data matrix
    x_o <- x
    x <- as.matrix(x %*% pca_decomp$rotation[, 1:ncomp])
    pca_flag <- TRUE

  } else {
    message("No reduction in dimensions by PCA")
    pca_flag <- FALSE
    ncomp <- ncol(x)
  }

  # Use mne-python lrate heuristic
  if (is.null(lrate)) {
    lrate <- .01 / log(ncomp^2)
  }

  # 3. perform whitening/sphering
  whitened_data <- do_whitening(x,
                                whiten)

  # 4. Train ICA
  start_time <- proc.time()
  rotation_mat <-
    ext_in(whitened_data$x_white,
           blocksize = blocksize,
           lrate = lrate,
           maxiter = maxiter,
           annealdeg = annealdeg,
           annealstep = anneal,
           tol = tol,
           random_seed = random_seed,
           verbose = verbose)

  unmix_mat <- crossprod(rotation_mat$weights,
                         whitened_data$white_cov)
  mixing_mat <- MASS::ginv(unmix_mat,
                           tol = 0)

  if (pca_flag) {
    mixing_mat <- pca_decomp[, 1:pca] %*% mixing_mat
  }

  comp_var <- colSums(mixing_mat^2)
  vafs <- comp_var / sum(comp_var)
  vaf_order <-
    sort(vafs,
       decreasing = TRUE,
       index.return = TRUE)$ix
  mixing_mat <- mixing_mat[, vaf_order]

  unmixing_mat <- t(MASS::ginv(mixing_mat,
                               tol = 0))

  if (pca_flag) {
     x <- x_o
  }

  if (verbose) {
    end_time <-  proc.time() - start_time
    message(paste0("ICA running time: ",
                   round(end_time[[3]], 3),
                   " s"))
  }

  S <- x %*% unmixing_mat
  colnames(S) <- sprintf("Comp%03d", 1:ncol(S))
  list(M = mixing_mat,
       W = unmixing_mat,
       S = S,
       iter = rotation_mat$iter)
}

ext_in <- function(x,
                   maxiter,
                   blocksize,
                   lrate,
                   kurt_size = 6000,
                   annealdeg,
                   annealstep,
                   tol,
                   extended = TRUE,
                   random_seed,
                   verbose = TRUE) {

  # Set the RNG seed
  if(!is.null(random_seed)) {
    set.seed(random_seed)
  }

  n_comps <- ncol(x)
  n_samps <- nrow(x)

  weights <- diag(n_comps)
  startweights <- weights
  oldweights <- weights
  oldchange <- 0

  bias <- array(0,
                dim = c(n_comps, 1))
  onesrow <- array(1,
                  dim = c(1, blocksize))

  BI <- blocksize * diag(n_comps)

  signs <- rep(1, n_comps)
  signs[1] <- -1

  iter <- 0
  extmomentum <- 0.5
  old_kurt <- 0
  signsbias <- .02
  max_weight <- 1e8

  # blowup and restart
  blowup_limit <- 1e9
  blowup <- FALSE
  blowup_fac <- 0.8
  restart_fac <- .9

  kurt_size <- min(kurt_size,
                   nrow(x))

  degconst <- 180 / pi

  delta <- numeric(n_comps^2)
  oldsigns <- numeric(n_comps)

  signcounts <- NULL
  extblocks <- 1
  signcount_threshold <- 25
  signcount_step <- 2
  blockno <- 1

  w_change <- tol
  min_lrate <- 1e-10

  nblock <- n_samps %/% blocksize
  lastt <- (nblock - 1) * blocksize + 1
  n_small_angle <- 20
  count_small_angle <- 0

  if (extended) {
    loss_fun <- tanh
    bias_fun <- function(y) {
      colSums(y) * - 2
    }

    update_weights <- function(weights,
                               BI,
                               signs,
                               n_comps,
                               u,
                               y) {
      weights %*% (BI - matrix(signs, n_comps, n_comps, byrow = TRUE) * crossprod(u, y) - crossprod(u))
    }

  } else {
    loss_fun <-
      function(u) {
        1 / (1 + exp(-u))
      }
    bias_fun <- function(y) {
      colSums(1 - 2 * y)
    }

    update_weights <- function(weights,
                               BI,
                               signs,
                               n_comps,
                               u,
                               y) {
      weights %*% (BI + crossprod(u, (1 - 2 * y)))
    }

  }

  while (iter < maxiter) {
    # shuffle timepoints
    perms <- sample.int(nrow(x))
    for (t in seq(1, lastt, by = blocksize)) {
      this_set <- perms[t:(t + blocksize - 1)]
      u <- x[this_set, ] %*% weights
      u <- u + matrix(bias[, 1],
                       blocksize,
                       n_comps,
                       byrow = TRUE)

      y <- loss_fun(u)

      #weights <- weights + lrate * weights %*% (BI - matrix(signs, n_comps, n_comps, byrow = TRUE) * crossprod(u, y) - crossprod(u))

      weights <- weights + lrate * update_weights(weights,
                                                  BI,
                                                  signs,
                                                  n_comps,
                                                  u,
                                                  y)
      bias <- bias + lrate * bias_fun(y) #colSums(y) * -2

      # check weights
      if (max(abs(weights)) > max_weight) {
        blowup <- TRUE
      }

      if (extended) {
        # kurtosis estimation
        if (extblocks > 0 & blockno %% extblocks == 0) {
          if (kurt_size < n_samps) {
            test_act <- x[sample.int(nrow(x), kurt_size), ] %*% weights
          } else {
            test_act <- x %*% weights
          }

          kurt <- colMeans(test_act * test_act * test_act * test_act) / colMeans(test_act^2)^2
          kurt <- kurt - 3

          if (extmomentum > 0) {
            kurt <- extmomentum * old_kurt + (1 - extmomentum) * kurt
            old_kurt <- kurt
          }

          signs <- sign(kurt + signsbias)

          if (isTRUE(all.equal(signs, oldsigns))) {
            signcount <- signcount + 1
          } else {
            signcount <- 0
          }

          oldsigns <- signs
          signcounts <- c(signcounts,
                          signcount)
          if (signcount >= signcount_threshold) {
            extblocks <- trunc(extblocks * signcount_step)
            signcount <- 0
          }
        }
      }
      blockno <- blockno + 1
      if (blowup) {
        break
      }
    }
    if (!blowup) {
      wtchange <- weights - oldweights
      iter <- iter + 1
      angledelta <- 0
      delta <- as.numeric(wtchange)
      change <- sum(wtchange * wtchange)

      if (iter > 2) {
        angledelta <- acos(sum(delta * olddelta) /
                             sqrt(change * oldchange))
        angledelta <- degconst * angledelta
      }

      oldweights <- weights

      if (verbose) {
        message(paste0(
          sprintf("Step: %d, lrate: %5f, wchange: %8.8f, angledelta: %4.1f",
                  iter,
                  lrate,
                  change,
                  angledelta)
          )
        )
      }

      if (angledelta > annealdeg) {
        lrate <- lrate * annealstep
        olddelta <- delta
        oldchange <- change
      } else {
        if (iter == 1) {
          olddelta <- delta
          oldchange <- change
        }
        if (n_small_angle > 0) {
           count_small_angle <- count_small_angle + 1
           if (count_small_angle > n_small_angle) {
             maxiter <- iter
           }
         }
      }

      if (iter > 2 & change < w_change) {
        iter <- maxiter
      } else if (change > blowup_limit) {
        lrate <- lrate * blowup_fac
      }

    } else {

      iter <- 0
      blowup <- FALSE
      blockno <- 1
      lrate <- lrate * restart_fac
      message(paste("Weights blown up, lowering lrate to ",
                    lrate))
      weights <- startweights
      oldweights <- startweights
      olddelta <- numeric(n_comps)
      bias <- array(0,
                    dim = c(n_comps, 1))

      extblocks <- 0
      signs <- rep(1, n_comps)
      signs[1] <- -1
      oldsigns <- numeric(n_comps)
    }

  }
  list(weights = weights,
       iter = iter)
}

do_whitening <- function(x,
                         whiten) {

  if (identical(whiten,
                "sqrtm")) {
    white_cov <- eigen(stats::cov(x))
    white_cov <- white_cov$vectors %*% diag(1/sqrt(white_cov$values)) %*% MASS::ginv(white_cov$vectors)
    white_cov <- 2 * white_cov
    x_white <- t(tcrossprod(white_cov,
                            x))
  } else {
    white_cov <-
      whitening::whiteningMatrix(stats::cov(as.matrix(x)),
                                 method = whiten)
    x_white <- whitening::whiten(x,
                                 method = whiten)
  }
  list(x_white = x_white,
       white_cov = white_cov)
}

