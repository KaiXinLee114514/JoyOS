/* TCC 自举测试:不 include 任何头文件(系统里没有 /include),
   自己声明 printf,TCC 编译 + 运行期链接 CRT_TCC.O/MINIC.O */
int printf(const char *fmt, ...);
int add(int a, int b);

int main(void)
{
    int x = add(2, 3);
    printf("hello from TCC ELF! 2+3=%d\n", x);
    printf("this program was compiled and linked *inside* JoyOS\n");
    return 0;
}

int add(int a, int b)
{
    return a + b;
}
