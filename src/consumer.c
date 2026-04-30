extern int inner(void);
extern int ext(void);
int consumer(void) { return inner() + ext(); }
