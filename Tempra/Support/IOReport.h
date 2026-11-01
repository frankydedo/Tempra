//
//  IOReport.h
//  GPU power from IOReport energy counters.
//

#ifndef TEMPRA_IOREPORT_H
#define TEMPRA_IOREPORT_H

/// Subscribes to IOReport's energy channels. Returns 0 on success.
int tempra_ioreport_open(void);
/// Average GPU power in watts since the previous call; -1 on the first call or on failure.
double tempra_ioreport_gpu_watts(void);

#endif
