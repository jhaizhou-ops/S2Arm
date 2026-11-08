#pragma once
#define EFD_CLOEXEC 0
#define EFD_NONBLOCK 0
int eventfd(unsigned int, int);
