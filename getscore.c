/*
 * getscore.c - reconstructed from binaries/getscore with Ghidra.
 *
 * Original build: 32-bit x86 ELF, GCC 3.2 (Red Hat Linux 8.0), with symbols.
 * The program is meant to run setuid: it switches to the effective uid,
 * looks up "name:SSN:score:" in score.txt and prints the score.
 *
 * Buffer sizes are inferred from the stack layout. GCC 3.2 pads stack
 * frames, so a few of these may be slightly larger than in the original.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/types.h>

FILE *scorefile;

/*
 * If `prefix` is a prefix of `str`, return a pointer to the first
 * character of `str` after the prefix. Otherwise return NULL.
 */
char *str_prefix(char *prefix, char *str)
{
    while (*prefix != '\0' && *str != '\0') {
        if (*prefix != *str)
            return NULL;
        prefix++;
        str++;
    }
    if (*prefix == '\0')
        return str;
    return NULL;
}

/*
 * Search score.txt for a line of the form "name:SSN:score:..." and copy
 * the score field into `score`. Returns 0 on success, -1 if not found.
 */
int get_score(char *name, char *ssn, char *score)
{
    char line[128];
    char matching_pattern[128];   /* 136 bytes in the frame, incl. padding */
    char *p;

    strcpy(matching_pattern, name);
    strcat(matching_pattern, ":");
    strcat(matching_pattern, ssn);

    do {
        if (fgets(line, 128, scorefile) == NULL)
            return -1;
        p = str_prefix(matching_pattern, line);
    } while (p == NULL || *p != ':');

    p++;
    while (*p != ':')
        *score++ = *p++;
    *score = '\0';

    return 0;
}

int main(int argc, char *argv[])
{
    char command[256];            /* 268 bytes in the frame, incl. padding */
    time_t current_time;
    char score[128];              /* 136 bytes in the frame, incl. padding */
    uid_t euid;
    uid_t uid;

    if (argc != 3) {
        printf("Usage: getscore name SSN\n");
        exit(1);
    }

    current_time = time(NULL);
    uid = getuid();               /* stored but never used */
    euid = geteuid();
    if (setreuid(euid, euid) != 0)
        perror("setreuid");

    scorefile = fopen("score.txt", "r");
    if (scorefile == NULL) {
        printf("failed to open score file\n");
    } else {
        if (get_score(argv[1], argv[2], score) != 0) {
            printf("Invalid user name or SSN.\n");
            sprintf(command,
                    "echo \"%s: Invalid user name or SSN: %s,%s\"|cat >> error.log",
                    ctime(&current_time), argv[1], argv[2]);
            if (system(command) != 0)
                perror("Logging");
            exit(-1);
        }
        printf("Your score is %s\n", score);
    }

    (void)uid;
    return 0;                     /* original was declared void main() */
}
