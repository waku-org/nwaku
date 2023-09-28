
#ifndef _BASE64_H_
#define _BASE64_H_

#include <stdlib.h>

size_t b64_encoded_size(size_t inlen);

void b64_encode(char* in, size_t len, std::vector<char>& out);

#endif
