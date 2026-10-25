#ifndef _MATH_H
#define _MATH_H
double ldexp(double x, int e);
double pow(double x, double y);
double strtod(const char *s, char **e);
float strtof(const char *s, char **e);
long double strtold(const char *s, char **e);
#define ldexpl ldexp
#define isnan(x) __builtin_isnan(x)
#define isinf(x) __builtin_isinf(x)
#define isfinite(x) __builtin_isfinite(x)
#endif
