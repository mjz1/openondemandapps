#!/bin/bash

# source $HOME/.bash_profile && \
rserver \
    --server-user="${RSTUDIO_USER}" \
    --www-port="${port}" \
    --auth-none=0 \
    --auth-pam-helper-path="${RSTUDIO_AUTH}" \
    --auth-encrypt-password=0 \
    --auth-timeout-minutes=0 \
    --rsession-path="${RSESSION_WRAPPER_FILE}"


# conda activate $COND_ENV && \

