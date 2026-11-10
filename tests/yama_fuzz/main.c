/* yama fuzz driver: reads cases from stdin and prints yama's alignment.
 * A case is "K M", M columns of A (K chars each), "L N", N columns of B,
 * then M+1 values of LB and M+1 values of RB.  Output: OM, then the OM
 * columns, A part then B part.  Built against any multiz tree, so two
 * trees' yama can be compared byte for byte (see run.sh).
 */
#include "util.h"
#include "mz_scores.h"
#include "mz_yama.h"
int main(void) {
    int K, M, L, N, i, OM, *LB, *RB;
    uchar **A, **B, **AL;
    static char buf[1 << 16];
    init_scores70();
    while (scanf("%d %d", &K, &M) == 2) {
        A = (uchar **)ckalloc(M*sizeof(uchar *)) - 1;
        for (i = 1; i <= M; i++) { if (scanf("%s", buf) != 1) return 1; A[i] = (uchar *)copy_string(buf); }
        if (scanf("%d %d", &L, &N) != 2) return 1;
        B = (uchar **)ckalloc(N*sizeof(uchar *)) - 1;
        for (i = 1; i <= N; i++) { if (scanf("%s", buf) != 1) return 1; B[i] = (uchar *)copy_string(buf); }
        LB = ckalloc((M+1)*sizeof(int)); RB = ckalloc((M+1)*sizeof(int));
        for (i = 0; i <= M; i++) if (scanf("%d", &LB[i]) != 1) return 1;
        for (i = 0; i <= M; i++) if (scanf("%d", &RB[i]) != 1) return 1;
        yama(A, K, M, B, L, N, LB, RB, &AL, &OM);
        printf("%d\n", OM);
        for (i = 1; i <= OM; i++) printf("%.*s\n", K+L, AL[i]);
        fflush(stdout);
        free(AL[1]); free(AL+1);
        for (i = 1; i <= M; i++) free(A[i]);
        for (i = 1; i <= N; i++) free(B[i]);
        free(A+1); free(B+1); free(LB); free(RB);
    }
    return 0;
}
