/* ============================================================================
 *  PLAY.C — 文本谱播放器:读 FAT 上的 .txt 谱子,让 PC 蜂鸣器唱出来
 *
 *  它证明"能听见 JoyOS 自己唱歌"这件事是**用户可改的**:谱子是纯文本,
 *  改一个音名就换一个音,不用重新编译内核、也不用重新编译这个程序。
 *
 *  用法(shell 里,run 会把整行剩下的部分当参数塞给程序):
 *      run PLAY RICK.TXT            按谱播放
 *      run PLAY --list RICK.TXT     只解析、把谱子打到屏幕上(不出声,方便核对)
 *      run PLAY                     打用法
 *
 *  ── 谱子格式(纯文本,人人可改)────────────────────────────────────────
 *      # 一个词的第一个字符是 # → 从这里到行尾都是注释
 *      tempo 120        # 每分钟多少拍(默认 120);四分音符 = 60000/tempo 毫秒
 *      A4  4            # 音名 + 时值:1 全音符 / 2 二分 / 4 四分 / 8 八分 / 16 十六分
 *      C#5 8            # 升号写 #(注意:音名里的 # 不是注释,只有"词首"的 # 才是)
 *      R   4            # R = 休止(不出声,只等这么久 —— 内核的 beep 支持 0 Hz 静音等待)
 *
 *  音名规则:字母 C D E F G A B(大小写都认)+ 可选 '#' + 一个八度数字(1~9),
 *  所以 C4~B5 当然没问题,再宽的两个八度也能写。
 *
 *  ── 为什么把频率表写死在 C 里 ──────────────────────────────────────────
 *  十二平均律本来可以现算(A4 = 440 Hz,相邻半音 ×2^(1/12)),但裸机环境没有 libm,
 *  手写指数/开方不值当。所以:一个八度(C4~B4)的 12 个频率写死,别的八度靠 ×2/÷2
 *  搬 —— 平均律里高八度正好是两倍频率,整数乘除不会跑调(误差只来自表本身的取整)。
 * ==========================================================================*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <joyos.h>

#define SCORE_MAX  16384                /* 谱子原文缓冲:纯文本的歌,16 KB 管够 */
#define MAX_NOTES  512                  /* 最多几个音(超了报错,而不是悄悄截断) */

/* 一条事件:音,或者休止(hz = 0) */
typedef struct {
    char name[6];                       /* 原样的音名,打谱子/播放时显示用:"A4" "C#5" "R" */
    int  hz;                            /* 频率 Hz,0 = 休止 */
    int  dur;                           /* 时值分母:1/2/4/8/16…(照原样留着,打印用) */
    int  ms;                            /* 折算成毫秒(由解析到这一行时的 tempo 决定) */
} note_t;

static char   score_text[SCORE_MAX];    /* 谱子原文(读进来后原地断行,所以不是 const) */
static note_t score[MAX_NOTES];
static int    note_count;
static int    score_tempo = 120;        /* 没写 tempo 就用 120 BPM,和乐谱行的默认一个意思 */

/* ---------------------------------------------------------------------------
 *  十二平均律,A4 = 440 Hz。表是 C4~B4 一个八度,四舍五入到整数 Hz ——
 *  蜂鸣器只有方波,差零点几赫兹没人听得出来;写死省掉一次 sqrt/exp。
 * -------------------------------------------------------------------------*/
static const int semitone_hz[12] = {
    262, 277, 294, 311, 330, 349, 370, 392, 415, 440, 466, 494
};
/* 字母 → 半音序号(相对 C):A=9 B=11 C=0 D=2 E=4 F=5 G=7 */
static const int letter_semitone[7] = { 9, 11, 0, 2, 4, 5, 7 };

/* ---------------------------------------------------------------------------
 *  从 *pp 抄出下一个空白分隔的词到 buf(最多 n-1 字符),没有词返回 0。
 *  为什么"抄出来"而不是就地截断:参数串是**内核**里的那块内存(0x11F000),
 *  程序不该去改它;抄一份两边都好用。
 * -------------------------------------------------------------------------*/
static int next_word(const char **pp, char *buf, int n)
{
    const char *s = *pp;
    int i = 0;

    while (*s == ' ' || *s == '\t' || *s == '\r')
        s++;
    if (!*s) {
        *pp = s;
        return 0;
    }
    while (*s && *s != ' ' && *s != '\t' && *s != '\r') {
        if (i < n - 1)
            buf[i++] = *s;
        s++;
    }
    buf[i] = 0;
    *pp = s;
    return 1;
}

/* ---------------------------------------------------------------------------
 *  音名 → 频率(写到 *hz_out;休止是 0)
 *  返回:0 = 认得,1 = 不认识这个音名,2 = 认得但超出蜂鸣器能发的范围
 * -------------------------------------------------------------------------*/
static int note_hz(const char *t, int *hz_out)
{
    int k, semi, oct, hz, n;
    char c;

    c = t[0];
    if (c >= 'a' && c <= 'z')
        c -= 'a' - 'A';
    if (c == 'R' && t[1] == 0) {        /* 休止:hz = 0,播放时走 j_beep(0, ms) */
        *hz_out = 0;
        return 0;
    }
    semi = -1;
    for (k = 0; k < 7; k++)
        if ("ABCDEFG"[k] == c)
            semi = letter_semitone[k];
    if (semi < 0)
        return 1;                       /* 不是 A~G 开头 → 名字不认识 */
    k = 1;
    if (t[k] == '#') {                  /* 升号:往高挪一个半音(B#4 就这样变成高八度的 C) */
        semi++;
        k++;
    }
    if (t[k] < '0' || t[k] > '9' || t[k + 1] != 0)
        return 1;                       /* 八度必须是个位数,而且到这儿就该结束 */
    oct = t[k] - '0';
    hz = semitone_hz[semi % 12];        /* 表只有 C4~B4 那段 */
    n = (oct - 4) * 12 + semi;          /* 相对 C4 差几个半音(可正可负) */
    while (n >= 12) {                   /* 高八度 = 频率 ×2 */
        hz *= 2;
        n -= 12;
    }
    while (n < 0) {                     /* 低八度 = 频率 ÷2 */
        hz /= 2;
        n += 12;
    }
    if (hz < 20 || hz > 20000)          /* 内核那边也会夹,但这里早点告诉用户更好 */
        return 2;
    *hz_out = hz;
    return 0;
}

/* 关键词比较,大小写不认:谱子是人手写的,写 "Tempo 120" 也该认 */
static int word_is(const char *w, const char *kw)
{
    int i;

    for (i = 0; kw[i]; i++) {
        char c = w[i];
        if (c >= 'A' && c <= 'Z')
            c += 'a' - 'A';
        if (c != kw[i])
            return 0;
    }
    return w[i] == 0;
}

/* ---------------------------------------------------------------------------
 *  解析 score_text → score[]。返回音符个数,失败返回 -1(错误信息已经打好了)。
 *  报错一定要带**行号**:谱子是人手改的,不报行号等于让人一行行去数。
 * -------------------------------------------------------------------------*/
static int parse_score(const char *fname)
{
    char *p = score_text;
    int line = 1;
    int count = 0;

    note_count = 0;
    while (*p) {
        const char *cursor;
        char *nl, name[8], w[16];
        int i, hz, dur, ms, digits;

        nl = strchr(p, '\n');
        if (nl)
            *nl = 0;                    /* 原地断行:下面按"整行"解析 */
        cursor = p;
        for (;;) {
            if (!next_word(&cursor, w, sizeof w))
                break;
            if (w[0] == '#')
                break;                  /* 词首是 # → 这一行剩下的都是注释 */
            if (word_is(w, "tempo")) {
                if (!next_word(&cursor, w, sizeof w) || w[0] == '#') {
                    printf("%s 第 %d 行:tempo 后面要跟一个数字(每分钟几拍)\n", fname, line);
                    return -1;
                }
                score_tempo = atoi(w);
                if (score_tempo < 20 || score_tempo > 400) {
                    printf("%s 第 %d 行:tempo %d 不像人听的谱子(写 20~400 BPM)\n",
                           fname, line, score_tempo);
                    return -1;
                }
                continue;
            }
            i = note_hz(w, &hz);
            if (i == 2) {
                printf("%s 第 %d 行:%s 超出蜂鸣器范围(只能发 20~20000 Hz)\n", fname, line, w);
                return -1;
            }
            if (i) {
                printf("%s 第 %d 行:不认识的音名 '%s'(音名像 A4 / C#5,休止写 R)\n",
                       fname, line, w);
                return -1;
            }
            strncpy(name, w, sizeof name - 1);
            name[sizeof name - 1] = 0;
            if (!next_word(&cursor, w, sizeof w) || w[0] == '#') {
                printf("%s 第 %d 行:音名 %s 后面缺时值(1=全音符 2=二分 4=四分 8=八分…)\n",
                       fname, line, name);
                return -1;
            }
            digits = (w[0] != 0);
            for (i = 0; w[i]; i++)
                if (w[i] < '0' || w[i] > '9')
                    digits = 0;
            dur = atoi(w);
            if (!digits || dur <= 0 || dur > 64) {
                printf("%s 第 %d 行:时值 '%s' 不对(1=全音符 2=二分 4=四分 8=八分…)\n",
                       fname, line, w);
                return -1;
            }
            if (count >= MAX_NOTES) {
                printf("%s 的音符超过 %d 个了(谱子太长,或者哪一行忘了换行)\n",
                       fname, MAX_NOTES);
                return -1;
            }
            /* 四分音符 = 60000/tempo 毫秒;时值 4 就是四分,whole(1) 是它的 4 倍 */
            ms = 240000 / (score_tempo * dur);
            if (ms < 1)
                ms = 1;
            strcpy(score[count].name, name);
            score[count].hz = hz;
            score[count].dur = dur;
            score[count].ms = ms;
            count++;
        }
        p = nl ? nl + 1 : p + strlen(p);
        line++;
    }
    note_count = count;
    if (count == 0) {
        printf("%s 里一个音都没有(空文件?整个文件被当成注释了?)\n", fname);
        return -1;
    }
    return count;
}

/* ---------------------------------------------------------------------------
 *  --list:把解析结果打到屏幕上(不发声)。
 *  这一屏是"可测"的那部分,自动化测试断言的就是它 —— 所以音名**原样**打出来,
 *  不换名、不合并休止,一行四个方便和谱子对着看。
 * -------------------------------------------------------------------------*/
static void print_score(const char *fname)
{
    int i, total = 0;

    j_color(JOY_LCYAN);
    printf("%s:tempo %d BPM(四分音符 = %d ms),%d 个音符\n",
           fname, score_tempo, 60000 / score_tempo, note_count);
    j_color(JOY_GREY);
    for (i = 0; i < note_count; i++) {
        total += score[i].ms;
        if (i % 4 == 0) {
            if (i)
                printf("\n");           /* 上一行满了才换行:行尾不留多余的 "|" */
            printf("  %2d: ", i + 1);
        } else {
            printf(" | ");
        }
        if (score[i].hz > 0)
            printf("%-3s %-2d %4d Hz", score[i].name, score[i].dur, score[i].hz);
        else
            printf("%-3s %-2d %4s   ", score[i].name, score[i].dur, "---");
    }
    printf("\n");
    printf("总时长约 %d.%d 秒(tempo 折算;时值是忙等估的,实际会差一点)\n",
           total / 1000, (total % 1000) / 100);
}

/* ---------------------------------------------------------------------------
 *  真的播:一个音一个音地打出来 + j_beep。休止走 j_beep(0, ms) ——
 *  内核那边 0 Hz 就是"静音等这么久",省得这里再写一套忙等。
 * -------------------------------------------------------------------------*/
static void play_score(const char *fname)
{
    int i;

    j_color(JOY_LCYAN);
    printf("播放 %s:%d 个音符,tempo %d BPM\n", fname, note_count, score_tempo);
    j_color(JOY_GREY);
    for (i = 0; i < note_count; i++) {
        if (score[i].hz > 0) {
            printf("  %-3s %-2d %4d Hz\n", score[i].name, score[i].dur, score[i].hz);
            j_beep(score[i].hz, score[i].ms);
        } else {
            printf("  %-3s %-2d   (休止)\n", score[i].name, score[i].dur);
            j_beep(0, score[i].ms);
        }
    }
    j_color(JOY_LGREEN);
    printf("演奏完了,再来一遍:run PLAY %s\n", fname);
}

static void usage(void)
{
    j_color(JOY_YELLOW);
    printf("用法:  run PLAY <谱子文件>            按谱播放\n");
    printf("       run PLAY --list <谱子文件>     只解析、打到屏幕上(不出声)\n");
    j_color(JOY_GREY);
    printf("谱子是纯文本(拿编辑器就能改):\n");
    printf("    # 词首的 # 是注释(tempo 120 后面也能跟 # 注释)\n");
    printf("    tempo 120       每分钟 120 拍,四分音符 = 500 ms\n");
    printf("    A4  4           音名 + 时值(1 全 2 半 4 四分 8 八分 16 十六分)\n");
    printf("    C#5 8           升号写 #;八度 1~9 都行\n");
    printf("    R   4           R = 休止\n");
    printf("现成两首:run PLAY RICK.TXT  /  run PLAY SCALE.TXT\n");
}

int main(void)
{
    const char *args = j_arg();
    const char *p = args;
    static char file_name[64];
    char w[32];
    int list = 0;
    int n;

    while (next_word(&p, w, sizeof w)) {
        if (!strcmp(w, "--list") || !strcmp(w, "-l")) {
            list = 1;
        } else if (!strcmp(w, "--help") || !strcmp(w, "-h")) {
            usage();
            return 0;
        } else if (w[0] == '-') {
            j_color(JOY_LRED);
            printf("不认识的选项:%s\n", w);
            usage();
            return 1;
        } else if (file_name[0]) {
            j_color(JOY_LRED);
            printf("一次只能给一个谱子文件(多出来的是 '%s')\n", w);
            usage();
            return 1;
        } else {
            strncpy(file_name, w, sizeof file_name - 1);   /* w 是复用的缓冲,得抄走 */
            file_name[sizeof file_name - 1] = 0;
        }
    }
    if (!file_name[0]) {
        usage();
        return 0;
    }

    n = j_readfile(file_name, score_text, SCORE_MAX - 1);
    if (n < 0) {
        j_color(JOY_LRED);
        printf("打不开谱子 %s\n", file_name);
        j_color(JOY_GREY);
        printf("  · 名字对不对?盘上都是 8.3 短名(shell 里 ls 看一眼)\n");
        printf("  · 也可能是文件太大,一次读不进来(上限 %d 字节)\n", SCORE_MAX - 1);
        return 1;
    }
    score_text[n] = 0;
    if (parse_score(file_name) < 0)
        return 1;
    if (list)
        print_score(file_name);
    else
        play_score(file_name);
    return 0;
}
