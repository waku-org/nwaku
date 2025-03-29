{.push raises: [].}

import metrics

declarePublicGauge lp_mix_success, "number of lightpush messages sent via mix"

declarePublicGauge lp_mix_failed, "number of lightpush messages failed via mix", labels =  ["error"]
