//
//  SMC.h
//  Read-only System Management Controller access (used for fan speeds).
//

#ifndef TEMPRA_SMC_H
#define TEMPRA_SMC_H

/// Opens the AppleSMC user client. Returns 0 on success.
int tempra_smc_open(void);
void tempra_smc_close(void);
/// Reads a four-character key (e.g. "F0Ac") as a number. Returns 0 on success.
int tempra_smc_read(const char *key, double *value);

#endif
