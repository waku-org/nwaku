#include <stdio.h>
#include <stddef.h>

#include "libwaku.h"

int main(int argc, char* argv[]) {
  char* string;
  NimMain();
  //echo();
  string = info("hello there");
  printf("Info: %s", string);
}
