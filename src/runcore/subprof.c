/*
Copyright (C) 2001-2011, Parrot Foundation.

=head1 NAME

src/runcore/subprof.c - Parrot's subroutine-level profiler

=head2 Functions

=over 4

=cut

*/

#include "parrot/runcore_api.h"
#include "parrot/embed.h"
#include "parrot/runcore_subprof.h"

#include "parrot/oplib/ops.h"
#include "parrot/oplib/core_ops.h"
#include "parrot/dynext.h"

#include "pmc/pmc_sub.h"
#include "pmc/pmc_callcontext.h"

#ifdef WIN32
#  define getpid _getpid
#endif

/* HEADERIZER HFILE: include/parrot/runcore_subprof.h */

/* HEADERIZER BEGIN: static */
/* Don't modify between HEADERIZER BEGIN / HEADERIZER END.  Your changes will be lost. */

static void buildcallchain(PARROT_INTERP, PMC *ctx, PMC *subpmc)
        __attribute__nonnull__(1);

static void finishcallchain(PARROT_INTERP)
        __attribute__nonnull__(1);

static void popcallchain(PARROT_INTERP)
        __attribute__nonnull__(1);

static void printspline(PARROT_INTERP, struct subprofile *sp)
        __attribute__nonnull__(1);

static void printspname(PARROT_INTERP, struct subprofile *sp)
        __attribute__nonnull__(1);

static inline const char * str2cs(PARROT_INTERP, STRING *s)
        __attribute__nonnull__(1);

static struct subprofile * sub2subprofile(PARROT_INTERP,
    PMC *ctx,
    PMC *subpmc)
        __attribute__nonnull__(1);

#define ASSERT_ARGS_buildcallchain __attribute__unused__ int _ASSERT_ARGS_CHECK = (\
       PARROT_ASSERT_ARG(interp))
#define ASSERT_ARGS_finishcallchain __attribute__unused__ int _ASSERT_ARGS_CHECK = (\
       PARROT_ASSERT_ARG(interp))
#define ASSERT_ARGS_popcallchain __attribute__unused__ int _ASSERT_ARGS_CHECK = (\
       PARROT_ASSERT_ARG(interp))
#define ASSERT_ARGS_printspline __attribute__unused__ int _ASSERT_ARGS_CHECK = (\
       PARROT_ASSERT_ARG(interp))
#define ASSERT_ARGS_printspname __attribute__unused__ int _ASSERT_ARGS_CHECK = (\
       PARROT_ASSERT_ARG(interp))
#define ASSERT_ARGS_str2cs __attribute__unused__ int _ASSERT_ARGS_CHECK = (\
       PARROT_ASSERT_ARG(interp))
#define ASSERT_ARGS_sub2subprofile __attribute__unused__ int _ASSERT_ARGS_CHECK = (\
       PARROT_ASSERT_ARG(interp))
/* Don't modify between HEADERIZER BEGIN / HEADERIZER END.  Your changes will be lost. */
/* HEADERIZER END: static */


static struct subprofile *
sub2subprofile(PARROT_INTERP, PMC *ctx, PMC *subpmc)
{
    Parrot_Sub_attributes *sub;
    int h;
    struct subprofile *sp, **spp;
    static struct subprofile *lastsp;

    PMC_get_sub(interp, subpmc, sub);
    if (lastsp && lastsp->sub == sub)
        return lastsp;
    h = ((int)sub >> 5) & 32767;
    for (spp = subprofilehash + h; (sp = *spp) != 0; spp = &sp->hnext)
        if (sp->sub == sub)
            break;
    if (!sp) {
        sp = (struct subprofile *)calloc(sizeof(struct subprofile), 1);
        sp->sub = sub;
        sp->subpmc = subpmc;
        *spp = sp;
    }
    lastsp = sp;
    return sp;
}

static inline const char *
str2cs(PARROT_INTERP, STRING *s)
{
    if (s == STRINGNULL)
        return "STRNULL";
    return Parrot_str_to_cstring(interp, s);
}

static void
popcallchain(PARROT_INTERP)
{
    struct subprofile *sp = cursp;
    struct subprofile *csp = sp->caller;
    if (csp) {
        csp->calls[sp->calleri].ops += sp->callerops;
        csp->calls[sp->calleri].ticks += sp->callerticks;
        csp->callerops += sp->callerops;
        csp->callerticks += sp->callerticks;
    }
    sp->ctx = 0;
    sp->callerops = 0;
    sp->callerticks = 0;
    sp->caller = 0;
    sp->calleri = 0;
    sp->ctx = 0;
    cursubpmc = csp ? csp->subpmc : 0;
    curctx = csp ? csp->ctx : 0;
    cursp = csp;
}

static void
finishcallchain(PARROT_INTERP)
{
    struct subprofile *sp, *csp;

    /* finish all calls */
    for (sp = cursp; sp; sp = csp) {
        csp = sp->caller;
        if (csp) {
            csp->calls[sp->calleri].ops += sp->callerops;
            csp->calls[sp->calleri].ticks += sp->callerticks;
            csp->callerops += sp->callerops;
            csp->callerticks += sp->callerticks;
        }
        sp->callerops = 0;
        sp->callerticks = 0;
        sp->caller = 0;
        sp->calleri = 0;
        sp->ctx = 0;
    }
    cursp = 0;
    curctx = 0;
    cursubpmc = 0;
}

static void
buildcallchain(PARROT_INTERP, PMC *ctx, PMC *subpmc)
{
    PMC *cctx;
    struct subprofile *sp;

    cctx = Parrot_pcc_get_caller_ctx(interp, ctx);
    if (cctx) {
        PMC *csubpmc = Parrot_pcc_get_sub(interp, cctx);
        if (curctx != cctx || cursubpmc != csubpmc)
            buildcallchain(interp, cctx, csubpmc);
    }
    if (PMC_IS_NULL(subpmc))
        return;
    sp = sub2subprofile(interp, ctx, subpmc);
    while (sp->ctx) {
        /* recursion! */
        if (!sp->rnext) {
            struct subprofile *rsp;
            rsp = (struct subprofile *)calloc(sizeof(struct subprofile), 1);
            rsp->sub = sp->sub;
            rsp->subpmc = sp->subpmc;
            rsp->rcnt = sp->rcnt + 1;
            sp->rnext = rsp;
        }
        sp = sp->rnext;
    }
    sp->ctx = ctx;
    sp->caller = cursp;
    if (cursp) {
        struct subprofile *csp = cursp;
        int i;
        for (i = 0; i < csp->ncalls; i++) if (csp->calls[i].callee == sp)
                break;
        if (i == csp->ncalls) {
            if ((csp->ncalls & 15) == 0) {
                if (csp->ncalls)
                    csp->calls = (struct callinfo *)realloc(csp->calls, sizeof(*csp->calls) * (csp->ncalls + 16));
                else
                    csp->calls = (struct callinfo *)malloc(sizeof(*csp->calls) * (csp->ncalls + 16));
            }
            memset(csp->calls + i, 0, sizeof(*csp->calls));
            csp->calls[i].callee = sp;
            csp->ncalls++;
        }
        sp->calleri = i;
    }
    cursp = sp;
    curctx = ctx;
    cursubpmc = subpmc;
}

static void
printspname(PARROT_INTERP, struct subprofile *sp)
{
    fprintf(stderr, "%p:%s", sp, str2cs(interp, sp->sub->name));
    if (sp->rcnt)
        fprintf(stderr, "'%d", sp->rcnt);
}

static void
printspline(PARROT_INTERP, struct subprofile *sp)
{
    PMC * annot;
    PackFile_Annotations *ann;
    PackFile_Annotations_Key *key;
    STRING *line_str = Parrot_str_new_constant(interp, "line");
    int i;

    if (!sp->sub || !sp->sub->seg || !sp->sub->seg->annotations)
        return;
    ann = sp->sub->seg->annotations;
    /* search for the first line annotation in our sub */
    for (i = 0; i < ann->num_keys; i++) {
        STRING * const test_key = ann->code->const_table->str.constants[ann->keys[i].name];
        if (STRING_equal(interp, test_key, line_str))
            break;

    }
    if (i < ann->num_keys) {
        /* ok, found the line key, now search for the sub */
        unsigned int j;
        key = ann->keys + i;
        for (j = key->start; j < key->start + key->len; j++) {
            if ((size_t)ann->base.data[j * 2 + ANN_ENTRY_OFF] < sp->sub->start_offs)
                continue;
            if ((size_t)ann->base.data[j * 2 + ANN_ENTRY_OFF] >= sp->sub->end_offs)
                continue;
            break;
        }
        if (j < key->start + key->len) {
            /* found it! */
            INTVAL line = ann->base.data[j * 2 + ANN_ENTRY_VAL];
            /* need +1, sigh */
            PMC *pfile = PackFile_Annotations_lookup(interp, ann, ann->base.data[j * 2 + ANN_ENTRY_OFF] + 1, Parrot_str_new_constant(interp, "file"));
            if (PMC_IS_NULL(pfile))
                fprintf(stderr, "???:%d", (int)line);
            else
                fprintf(stderr, "%s:%d", str2cs(interp, VTABLE_get_string(interp, pfile)), (int)line);
        }
    }
}

void
dump_profile_data(PARROT_INTERP)
{
    int h;
    size_t off;

    if (!totalops)
        return;
    fprintf(stderr, "events: ops ticks\n");
    fprintf(stderr, "summary: %d %lld\n", totalops, totalticks);
    finishcallchain(interp);	/* just in case... */

    for (h = 0; h < 32767; h++) {
        struct subprofile *hsp;
        for (hsp = subprofilehash[h]; hsp; hsp = hsp->hnext) {
            struct subprofile *sp;
            for (sp = hsp; sp; sp = sp->rnext) {
                int i;

                fprintf(stderr, "\n");
                fprintf(stderr, "fl=");
                printspline(interp, sp);
                fprintf(stderr, "\n");
                fprintf(stderr, "fn=");
                printspname(interp, sp);
                fprintf(stderr, "\n");
                fprintf(stderr, "0 %d %lld\n", sp->ops, sp->ticks);
                for (i = 0; i < sp->ncalls; i++) {
                    struct subprofile *csp = sp->calls[i].callee;
                    fprintf(stderr, "cfl=");
                    printspline(interp, csp);
                    fprintf(stderr, "\n");
                    fprintf(stderr, "cfn=");
                    printspname(interp, csp);
                    fprintf(stderr, "\n");
                    fprintf(stderr, "calls=%d 0\n", sp->calls[i].count);
                    fprintf(stderr, "0 %d %lld\n", sp->calls[i].ops, sp->calls[i].ticks);
                }
            }
        }
    }
    fprintf(stderr, "\ntotals: %d %lld\n", totalops, totalticks);
}

/*
   __asm__ __volatile__ (
   "xorl %%eax,%%eax \n        cpuid"
   ::: "%rax", "%rbx", "%rcx", "%rdx");
   */

__inline__ uint64_t rdtsc(void) {
    uint32_t lo, hi; 
    __asm__ __volatile__ ("rdtsc" : "=a" (lo), "=d" (hi));
    return (uint64_t)hi << 32 | lo; 
}

void
profile(PARROT_INTERP, PMC *ctx, opcode_t *pc)
{
    PMC *subpmc;
    PackFile_ByteCode  *code = interp->code;
    struct subprofile *sp;

    uint64_t tick;

    /* finish old ticks */
    tick = rdtsc();
    if (tickadd) {
        uint64_t tickdiff = tick - starttick;
        *tickadd += tickdiff;
        *tickadd2 += tickdiff;
        totalticks += tickdiff;
        starttick = tick;
    }

    subpmc = Parrot_pcc_get_sub(interp, ctx);
    if (PMC_IS_NULL(subpmc))
        return;

    if (subpmc != cursubpmc || ctx != curctx) {
        /* context changed! either called new sub or returned from sub */
        if (cursp) {
            /* optimize common cases */
            /* did we just return? */
            if (cursp->caller && cursp->caller->subpmc == subpmc && cursp->caller->ctx == ctx) {
                /* a simple return */
                popcallchain(interp);
            }
            else {
                PMC *cctx = Parrot_pcc_get_caller_ctx(interp, ctx);
                PMC *csubpmc = Parrot_pcc_get_sub(interp, cctx);
                if (curctx == cctx && cursubpmc == csubpmc) {
                    /* a simple call */
                    buildcallchain(interp, ctx, subpmc);
                }
                else if (cursp->caller && cursp->caller->subpmc == csubpmc && cursp->caller->ctx == cctx) {
                    /* some kind of tailcall */
                    popcallchain(interp);
                    buildcallchain(interp, ctx, subpmc);
                }
            }
        }
        if (subpmc != cursubpmc || ctx != curctx) {
            /* out of luck! redo call chain */
            finishcallchain(interp);
            buildcallchain(interp, ctx, subpmc);
        }
        sp = cursp;
        if (pc == sp->sub->seg->base.data + sp->sub->start_offs) {
            /* assume new call */
            if (sp->caller)
                sp->caller->calls[sp->calleri].count++;
        }
        tickadd = &sp->ticks;
        tickadd2 = &sp->callerticks;
        starttick = rdtsc();
    }
    sp = cursp;
    sp->ops++;
    sp->callerops++;	/* to distribute */
    totalops++;
}

/*

=back

=cut

*/

/*
 * Local variables:
 *   c-file-style: "parrot"
 * End:
 * vim: expandtab shiftwidth=4 cinoptions='\:2=2' :
 */