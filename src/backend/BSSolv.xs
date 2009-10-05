#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#define MULTI_SEMANTICS

#include "pool.h"
#include "repo.h"
#include "util.h"
#include "evr.h"
#include "hash.h"
#include "repo_solv.h"
#include "repo_write.h"
#include "repo_rpmdb.h"
#include "repo_deb.h"

typedef struct _Expander {
  Pool *pool;

  Map ignored;
  Map ignoredx;

  Queue preferposq;
  Map preferpos;
  Map preferposx;

  Map preferneg;
  Map prefernegx;

  Queue conflictsq;
  Map conflicts;

  int debug;
} Expander;

typedef Pool *BSSolv__pool;
typedef Repo *BSSolv__repo;
typedef Expander *BSSolv__expander;

static Id buildservice_id;
static Id buildservice_repocookie;
static Id buildservice_external;

/* make sure bit n is usable */
#define MAPEXP(m, n) ((m)->size < (((n) + 8) >> 3) ? map_grow(m, n + 256) : 0)

#define REPOCOOKIE "buildservice repo 1.0"

static int
myrepowritefilter(Repo *repo, Repokey *key, void *kfdata)
{
  int i;
  if (key->name == SOLVABLE_URL)
    return KEY_STORAGE_DROPPED;
  if (key->name == SOLVABLE_HEADEREND)
    return KEY_STORAGE_DROPPED;
  if (key->name == SOLVABLE_PACKAGER)
    return KEY_STORAGE_DROPPED;
  if (key->name == SOLVABLE_GROUP)
    return KEY_STORAGE_DROPPED;
  if (key->name == SOLVABLE_LICENSE)
    return KEY_STORAGE_DROPPED;
  i = repo_write_stdkeyfilter(repo, key, kfdata);
  if (i == KEY_STORAGE_VERTICAL_OFFSET)
    return KEY_STORAGE_DROPPED;
  return i;
}

static inline char *
hvlookupstr(HV *hv, const char *key, int keyl)
{
  SV **svp = hv_fetch(hv, key, keyl, 0);
  if (!svp)
    return 0;
  return SvPV_nolen(*svp);
}

static inline AV *
hvlookupav(HV *hv, const char *key, int keyl)
{
  SV *sv, **svp = hv_fetch(hv, key, keyl, 0);
  if (!svp)
    return 0;
  sv = *svp;
  if (!sv || !SvROK(sv) || SvTYPE(SvRV(sv)) != SVt_PVAV)
    return 0;
  return (AV *)SvRV(sv);
}

static Id
makeevr(Pool *pool, char *e, char *v, char *r)
{
  char *s;

  if (!v)
    return 0;
  if (e && !strcmp(e, "0"))
    e = 0;
  if (e)
    s = pool_tmpjoin(pool, e, ":", v);
  else
    s = v;
  if (r)
    s = pool_tmpjoin(pool, s, "-", r);
  return str2id(pool, s, 1);
}

static inline char *
avlookupstr(AV *av, int n)
{
  SV **svp = av_fetch(av, n, 0);
  if (!svp)
    return 0;
  return SvPV_nolen(*svp);
}

static inline Id
id2name(Pool *pool, Id id)
{
  while (ISRELDEP(id))
    {
      Reldep *rd = GETRELDEP(pool, id);
      id = rd->name;
    }
  return id;
}

static Id
dep2id(Pool *pool, char *s)
{
  char *n;
  Id id;
  int flags;

  if ((n = strchr(s, '|')) != 0)
    {
      id = dep2id(pool, n + 1);
      *n = 0;
      id = rel2id(pool, dep2id(pool, s), id, REL_OR, 1);
      *n = '|';
      return id;
    }
  while (*s == ' ' || *s == '\t')
    s++;
  n = s;
  while (*s && *s != ' ' && *s != '\t' && *s != '<' && *s != '=' && *s != '>')
    s++;
  id = strn2id(pool, n, s - n, 1);
  if (!*s)
    return id;
  while (*s == ' ' || *s == '\t')
    s++;
  flags = 0;
  for (;;s++)
    {
      if (*s == '<')
	flags |= REL_LT;
      else if (*s == '=')
	flags |= REL_EQ;
      else if (*s == '>')
	flags |= REL_GT;
      else
	break;
    }
  if (!flags)
    return id;
  while (*s == ' ' || *s == '\t')
    s++;
  return rel2id(pool, id, str2id(pool, s, 1), flags, 1);
}

static inline void
expander_installed(Expander *xp, Id p, Map *installed, Map *conflicts, Queue *out, Queue *todo)
{
  Pool *pool = xp->pool;
  Solvable *s = pool->solvables + p;
  Id req, id, *reqp;
  const char *n;

  MAPSET(installed, p);
  queue_push(out, p);
  if (MAPTST(&xp->conflicts, s->name))
    {
      int i;
      for (i = 0; i < xp->conflictsq.count; i++)
	{
	  Id p2, pp2;
	  Id id = xp->conflictsq.elements[i];
	  if (id != s->name)
	    continue;
	  id = xp->conflictsq.elements[i ^ 1];
	  FOR_PROVIDES(p2, pp2, id)
	    {
	      if (pool->solvables[p2].name == id)
		{
		  MAPEXP(conflicts, pool->nsolvables);
	          MAPSET(conflicts, p2);
		}
	    }
	}
    }
  if (s->requires)
    {
      reqp = s->repo->idarraydata + s->requires;
      while ((req = *reqp++) != 0)
	{
	  if (req == SOLVABLE_PREREQMARKER)
	    continue;
	  id = id2name(pool, req);
	  if (MAPTST(&xp->ignored, id))
	    continue;
	  if (MAPTST(&xp->ignoredx, id))
	    {
	      Id xid = str2id(pool, pool_tmpjoin(pool, id2str(pool, s->name), ":", id2str(pool, id)), 0);
	      if (xid && MAPTST(&xp->ignored, xid))
		continue;
	    }
	  n = id2str(pool, id);
	  if (!strncmp(n, "rpmlib(", 7))
	    {
	      MAPEXP(&xp->ignored, id);
	      MAPSET(&xp->ignored, id);
	      continue;
	    }
	  if (*n == '/')
	    {
	      MAPEXP(&xp->ignored, id);
	      MAPSET(&xp->ignored, id);
	      continue;
	    }
	  queue_push2(todo, req, p);
	}
    }
}

#define ERROR_NOPROVIDER 1
#define ERROR_CHOICE	 2


int
expander_expand(Expander *xp, Queue *in, Queue *out)
{
  Pool *pool = xp->pool;
  Queue todo, errors, cerrors, qq, posfoundq;
  Map installed;
  Map conflicts;
  Solvable *s;
  Id q, p, pp;
  int i, j, nerrors, doamb, ambcnt;
  Id id, who, whon, pn;

  map_init(&installed, pool->nsolvables);
  map_init(&conflicts, 0);
  queue_init(&todo);
  queue_init(&qq);
  queue_init(&errors);
  queue_init(&cerrors);
  queue_init(&posfoundq);

  queue_empty(out);

  /* do direct expands */
  for (i = 0; i < in->count; i++)
    {
      id = in->elements[i];
      q = 0;
      FOR_PROVIDES(p, pp, id)
	{
	  s = pool->solvables + p;
	  if (!pool_match_nevr(pool, s, id))
	    continue;
	  if (q)
	    {
	      q = 0;
	      break;
	    }
	  q = p;
	}
      if (q)
	{
	  if (MAPTST(&installed, q))
	    continue;
	  if (xp->debug)
	    {
	      printf("added %s because of %s (direct dep)\n", id2str(pool, pool->solvables[q].name), dep2str(pool, id));
	      fflush(stdout);
	    }
	  expander_installed(xp, q, &installed, &conflicts, out, &todo); /* unique match! */
	}
      else
	queue_push2(&todo, id, 0);
    }

  doamb = 0;
  ambcnt = todo.count;
  while (todo.count)
    {
      id = queue_shift(&todo);
      who = queue_shift(&todo);
      if (ambcnt == 0)
	{
	  if (doamb)
	    break;	/* amb pass had no progress, stop */
	  if (xp->debug)
	    {
	      printf("now doing undecided dependencies\n");
	      fflush(stdout);
	    }
	  doamb = 1;	/* start amb pass */
	  ambcnt = todo.count;
	}
      else
	ambcnt -= 2;
// printf("todo %s %s ambcnt %d\n", id2str(pool, pool->solvables[who].name), dep2str(pool, id), ambcnt);
// fflush(stdout);
      whon = pool->solvables[who].name;
      queue_empty(&qq);
      FOR_PROVIDES(p, pp, id)
	{
	  Id pn;
	  if (MAPTST(&installed, p))
	    break;
	  pn = pool->solvables[p].name;
	  if (who && MAPTST(&xp->ignored, pn))
	    break;
	  if (who && MAPTST(&xp->ignoredx, pn))
	    {
	      Id xid = str2id(pool, pool_tmpjoin(pool, id2str(pool, whon), ":", id2str(pool, pn)), 0);
	      if (xid && MAPTST(&xp->ignored, xid))
		break;
	    }
	  if (conflicts.size && MAPTST(&conflicts, p))
	    continue;
	  queue_push(&qq, p);
	}
      if (p)
	continue;
      if (qq.count == 0)
	{
	  queue_push(&errors, ERROR_NOPROVIDER);
	  queue_push2(&errors, id, who);
	  continue;
	}
      if (qq.count > 1 && !doamb)
	{
	  /* try again later */
	  queue_push2(&todo, id, who);
	  if (xp->debug)
	    {
	      printf("undecided about %s:%s:", id2str(pool, whon), dep2str(pool, id));
	      for (i = 0; i < qq.count; i++)
	        printf(" %s", id2str(pool, pool->solvables[qq.elements[i]].name));
	      printf("\n");
	      fflush(stdout);
	    }
	  continue;
	}

      /* prune neg prefers */
      if (qq.count > 1)
	{
	  for (i = j = 0; i < qq.count; i++)
	    {
	      p = qq.elements[i];
	      pn = pool->solvables[p].name;
	      if (MAPTST(&xp->preferneg, pn))
		continue;
	      if (who && MAPTST(&xp->prefernegx, pn))
		{
		  Id xid = str2id(pool, pool_tmpjoin(pool, id2str(pool, whon), ":", id2str(pool, pn)), 0);
		  if (xid && MAPTST(&xp->preferneg, xid))
		    continue;
		}
	      qq.elements[j++] = p;
	    }
	  if (j)
	    queue_truncate(&qq, j);
	}

      /* prune pos prefers */
      if (qq.count > 1)
	{
	  queue_empty(&posfoundq);
	  for (i = j = 0; i < qq.count; i++)
	    {
	      p = qq.elements[i];
	      pn = pool->solvables[p].name;
	      if (MAPTST(&xp->preferpos, pn))
		{
		  queue_push2(&posfoundq, pn, p);
		  qq.elements[j++] = p;
		  continue;
		}
	      if (who && MAPTST(&xp->preferposx, pn))
		{
		  Id xid = str2id(pool, pool_tmpjoin(pool, id2str(pool, whon), ":", id2str(pool, pn)), 0);
		  if (xid && MAPTST(&xp->preferpos, xid))
		    {
		      queue_push2(&posfoundq, pn, p);
		      qq.elements[j++] = p;
		      continue;
		    }
		}
	    }
	  if (posfoundq.count == 2)
	    {
	      queue_empty(&qq);
	      queue_push(&qq, posfoundq.elements[1]);
	    }
	  else if (posfoundq.count)
	    {
	      /* found a pos prefer, now find first hit */
	      /* (prefers are ordered) */
	      for (i = 0; i < xp->preferposq.count; i++)
		{
		  Id xid = xp->preferposq.elements[i];
		  for (j = 0; j < posfoundq.count; j += 2)
		    if (posfoundq.elements[j] == xid)
		      break;
		  if (j < posfoundq.count)
		    {
		      queue_empty(&qq);
		      queue_push(&qq, posfoundq.elements[j + 1]);
		      break;
		    }
		}
	    }
	}

      /* prune OR deps */
      if (qq.count > 1 && ISRELDEP(id) && GETRELDEP(pool, id)->flags == REL_OR)
	{
	  Id rid = id;
	  for (;;)
	    {
	      Reldep *rd = 0;
	      if (ISRELDEP(rid))
		{
		  rd = GETRELDEP(pool, rid);
		  if (rd->flags != REL_OR)
		    rd = 0;
		}
	      if (rd)
		rid = rd->name;
	      queue_empty(&qq);
	      FOR_PROVIDES(p, pp, rid)
		queue_push(&qq, p);
	      if (qq.count)
		break;
	      if (rd)
	        rid = rd->evr;
	      else
		break;
	    }
	}
      if (qq.count > 1)
	{
	  queue_push(&cerrors, ERROR_CHOICE);
	  queue_push2(&cerrors, id, who);
	  for (i = 0; i < qq.count; i++)
	    queue_push(&cerrors, qq.elements[i]);
	  queue_push(&cerrors, 0);
	  /* try again later */
	  queue_push2(&todo, id, who);
	  continue;
	}
      if (xp->debug)
	{
	  printf("added %s because of %s:%s\n", id2str(pool, pool->solvables[qq.elements[0]].name), id2str(pool, whon), dep2str(pool, id));
	  fflush(stdout);
	}
      expander_installed(xp, qq.elements[0], &installed, &conflicts, out, &todo);
      doamb = 0;
      ambcnt = todo.count;
      queue_empty(&cerrors);
    }
  map_free(&installed);
  nerrors = 0;
  if (errors.count || cerrors.count)
    {
      queue_empty(out);
      for (i = 0; i < errors.count; i += 3)
	{
	  queue_push(out, errors.elements[i]);
	  queue_push(out, errors.elements[i + 1]);
	  queue_push(out, errors.elements[i + 2]);
	  nerrors++;
	}
      for (i = 0; i < cerrors.count; )
	{
	  queue_push(out, cerrors.elements[i]);
	  queue_push(out, cerrors.elements[i + 1]);
	  queue_push(out, cerrors.elements[i + 2]);
	  i += 3;
	  while (cerrors.elements[i])
	    {
	      queue_push(out, cerrors.elements[i]);
	      i++;
	    }
	  queue_push(out, 0);
	  i++;
	  nerrors++;
	}
    }
  else
    {
      if (todo.count)
	{
	  fprintf(stderr, "Internal expansion error!\n");
	  queue_empty(out);
	  queue_push(out, ERROR_NOPROVIDER);
	  queue_push(out, 0);
	  queue_push(out, 0);
	}
    }
  queue_free(&todo);
  queue_free(&qq);
  queue_free(&errors);
  queue_free(&cerrors);
  queue_free(&posfoundq);
  return nerrors;
}

void
create_considered(Pool *pool, Repo *repoonly, Map *considered)
{
  Id p, pb,*best;
  Solvable *s, *sb;
  int ridx;
  Repo *repo;

  map_init(considered, pool->nsolvables);
  best = sat_calloc(sizeof(Id), pool->ss.nstrings);
  FOR_REPOS(ridx, repo)
    {
      if (repoonly && repo != repoonly)
	continue;
      FOR_REPO_SOLVABLES(repo, p, s)
	{
	  if (s->arch == ARCH_SRC || s->arch == ARCH_NOSRC)
	    continue;
	  pb = best[s->name];
	  if (pb)
	    {
	      sb = pool->solvables + pb;
	      if (s->repo != sb->repo)
		continue;	/* first repo wins */
	      else if (s->arch != sb->arch)
		{
		  int r;
		  if (s->arch == ARCH_NOARCH || s->arch == ARCH_ALL)
		    continue;
		  if (sb->arch != ARCH_NOARCH && sb->arch != ARCH_ALL)
		    {
		      r = strcmp(id2str(pool, sb->arch), id2str(pool, s->arch));
		      if (r >= 0)
			continue;
		    }
		}
	      else if (s->evr != sb->evr)
		{
		  /* same repo, check versions */
		  int r = evrcmp(pool, sb->evr, s->evr, EVRCMP_COMPARE);
		  if (r > 0)
		    continue;
		  else if (r == 0)
		    {
		      r = strcmp(id2str(pool, sb->evr), id2str(pool, s->evr));
		      if (r >= 0)
			continue;
		    }
		}
	      else
		continue;
	      MAPCLR(considered, pb);
	    }
	  best[s->name] = p;
	  MAPSET(considered, p);
	}
    }
  sat_free(best);
}

struct metaline {
  char *l;
  int lastoff;
  int nslash;
  int killed;
};

static int metacmp(const void *ap, const void *bp)
{
  const struct metaline *a, *b;
  int r;

  a = ap;
  b = bp;
  r = a->nslash - b->nslash;
  if (r)
    return r;
  r = strcmp(a->l + 34, b->l + 34);
  if (r)
    return r;
  r = strcmp(a->l, b->l);
  if (r)
    return r;
  return a - b;
}


Id
repodata_addbin(Repodata *data, char *path, char *s, int sl, char *sid)
{
  Pool *pool = data->repo->pool;
  char *sp;
  Id p;

  p = pool->nsolvables;
  if (!strcmp(s + sl - 4, ".rpm"))
    repo_add_rpms(data->repo, (const char **)&path, 1, REPO_REUSE_REPODATA|REPO_NO_INTERNALIZE|RPM_ADD_WITH_PKGID|RPM_ADD_NO_FILELIST|RPM_ADD_NO_RPMLIBREQS);
  else if (!strcmp(s + sl - 4, ".deb"))
    repo_add_debs(data->repo, (const char **)&path, 1, REPO_REUSE_REPODATA|REPO_NO_INTERNALIZE|DEBS_ADD_WITH_PKGID);
  else
    return 0;
  if (pool->nsolvables == p)
    return 0;
  if ((sp = strrchr(s, '/')) != 0)
    {
      *sp = 0;
      repodata_set_str(data, p, SOLVABLE_MEDIADIR, s);
      *sp = '/';
    }
  else
    repodata_delete_uninternalized(data, p, SOLVABLE_MEDIADIR);
  repodata_set_str(data, p, buildservice_id, sid);
  return p;
}

MODULE = BSSolv		PACKAGE = BSSolv

void
depsort(HV *deps, SV *mapp, SV *cycp, ...)
    PPCODE:
	{
	    int i, j, k, cy, cycstart, nv;
	    SV *sv, **svp;
	    Id id, *e;
	    Id *mark;
	    char **names;
	    Hashmask hm;
	    Hashtable ht;
	    Hashval h, hh;
	    HV *mhv = 0;

	    Queue edata;
	    Queue vedge;
	    Queue todo;
	    Queue cycles;

	    if (items == 3)
	      XSRETURN_EMPTY; /* nothing to sort */
	    if (items == 4)
	      {
		/* only one item */
		char *s = SvPV_nolen(ST(2));
		EXTEND(SP, 1);
		sv = newSVpv(s, 0);
		PUSHs(sv_2mortal(sv));
	        XSRETURN(1); /* nothing to sort */
	      }

	    if (mapp && SvROK(mapp) && SvTYPE(SvRV(mapp)) == SVt_PVHV)
	      mhv = (HV *)SvRV(mapp);

	    queue_init(&edata);
	    queue_init(&vedge);
	    queue_init(&todo);
	    queue_init(&cycles);

	    hm = mkmask(items);
	    ht = sat_calloc(hm + 1, sizeof(*ht));
	    names = sat_calloc(items, sizeof(char *));
	    nv = 1;
	    for (i = 3; i < items; i++)
	      {
		char *s = SvPV_nolen(ST(i));
		h = strhash(s) & hm;
		hh = HASHCHAIN_START;
		while ((id = ht[h]) != 0)
		  {
		    if (!strcmp(names[id], s))
		      break;
		    h = HASHCHAIN_NEXT(h, hh, hm);
		  }
		if (id)
		  continue;	/* had that one before, ignore */
		id = nv++;
		ht[h] = id;
		names[id] = s;
	      }

	    /* we now know all vertices, create edges */
	    queue_push(&vedge, 0);
	    queue_push(&edata, 0);
	    for (i = 1; i < nv; i++)
	      {
		svp = hv_fetch(deps, names[i], strlen(names[i]), 0);
		sv = svp ? *svp : 0;
		queue_push(&vedge, edata.count);
		if (sv && SvROK(sv) && SvTYPE(SvRV(sv)) == SVt_PVAV)
		  {
		    AV *av = (AV *)SvRV(sv);
		    for (j = 0; j <= av_len(av); j++)
		      {
			char *s;
			STRLEN slen;

			svp = av_fetch(av, j, 0);
			if (!svp)
			  continue;
			sv = *svp;
			s = SvPV(sv, slen);
			if (!s)
			  continue;
			if (mhv)
			  {
			    /* look up in dep map */
			    svp = hv_fetch(mhv, s, slen, 0);
			    if (svp)
			      {
				s = SvPV(*svp, slen);
				if (!s)
				  continue;
			      }
			  }
			/* look up in hash */
			h = strhash(s) & hm;
			hh = HASHCHAIN_START;
			while ((id = ht[h]) != 0)
			  {
			    if (!strcmp(names[id], s))
			      break;
			    h = HASHCHAIN_NEXT(h, hh, hm);
			  }
			if (!id)
			  continue;	/* not known, ignore */
			if (id == i)
			  continue;	/* no self edge */
			queue_push(&edata, id);
		      }
		  }
		queue_push(&edata, 0);
	      }
	    sat_free(ht);

	    if (0)
	      {
		printf("vertexes: %d\n", vedge.count - 1);
		for (i = 1; i < vedge.count; i++)
		  {
		    printf("%d %s:", i, names[i]);
		    Id *e = edata.elements + vedge.elements[i];
		    for (; *e; e++)
		      printf(" %d", *e);
		    printf("\n");
		  }
	      }
		

	    /* now everything is set up, sort em! */
	    mark = sat_calloc(vedge.count, sizeof(Id));
	    for (i = vedge.count - 1; i; i--)
	      queue_push(&todo, i);
	    EXTEND(SP, vedge.count - 1);
	    while (todo.count)
	      {
		i = queue_pop(&todo);
		// printf("check %d\n", i);
		if (i < 0)
		  {
		    i = -i;
		    mark[i] = 2;
		    sv = newSVpv(names[i], 0);
		    PUSHs(sv_2mortal(sv));
		    continue;
		  }
		if (mark[i] == 2)
		  continue;
		if (mark[i] == 0)
		  {
		    int edgestovisit = 0;
		    Id *e = edata.elements + vedge.elements[i];
		    for (; *e; e++)
		      {
			if (*e == -1)
			  continue;	/* broken */
			if (mark[*e] == 2)
			  continue;
			if (!edgestovisit++)
			  queue_push(&todo, -i);
		        queue_push(&todo, *e);
		      }
		    if (!edgestovisit)
		      {
			mark[i] = 2;
			sv = newSVpv(names[i], 0);
			PUSHs(sv_2mortal(sv));
		      }
		    else
		      mark[i] = 1;
		    continue;
		  }
		/* oh no, we found a cycle, record and break it */
		cy = cycles.count;
		for (j = todo.count - 1; j >= 0; j--)
		  if (todo.elements[j] == -i)
		    break;
		cycstart = j;
		// printf("cycle:\n");
		for (j = cycstart; j < todo.count; j++)
		  if (todo.elements[j] < 0)
		    {
		      k = -todo.elements[j];
		      mark[k] = 0;
		      queue_push(&cycles, k);
		      // printf("  %d\n", k);
		    }
	        queue_push(&cycles, 0);
		todo.elements[cycstart] = i;
		/* break it */
		for (k = cy; cycles.elements[k]; k++)
		  ;
		if (!cycles.elements[k])
		  k = cy;
		j = cycles.elements[k + 1] ? cycles.elements[k + 1] : cycles.elements[cy];
		k = cycles.elements[k];
		/* breaking edge from k -> j */
		// printf("break %d -> %d\n", k, j);
		e = edata.elements + vedge.elements[k];
		for (; *e; e++)
		  if (*e == j)
		    break;
		if (!*e)
		  abort();
		*e = -1;
		todo.count = cycstart + 1;
	      }

	    /* recored cycles */
	    if (cycles.count && cycp && SvROK(cycp) && SvTYPE(SvRV(cycp)) == SVt_PVAV)
	      {
		AV *av = (AV *)SvRV(cycp);
		for (i = 0; i < cycles.count;)
		  {
		    AV *av2 = newAV();
		    for (; cycles.elements[i]; i++)
		      {
			SV *sv = newSVpv(names[cycles.elements[i]], 0);
			av_push(av2, sv);
		      }
		    av_push(av, newRV_inc((SV*)av2));
		    i++;
		  }
	      }
	    queue_free(&cycles);

	    queue_free(&edata);
	    queue_free(&vedge);
	    queue_free(&todo);
	    sat_free(mark);
	    sat_free(names);
	}

void
gen_meta(AV *subp, ...)
    PPCODE:
	{
	    Hashmask hm;
	    Hashtable ht;
	    Hashval h, hh;
	    char **subpacks;
	    struct metaline *lines, *lp;
	    int nlines;
	    int i, j, cycle, ns;
	    char *s, *s2, *lo;
	    Id id;
	    Queue cycles;
	    Id cycles_buf[64];

	    if (items == 1)
	      XSRETURN_EMPTY; /* nothing to generate */

	    queue_init_buffer(&cycles, cycles_buf, sizeof(cycles_buf)/sizeof(*cycles_buf));
	    hm = mkmask(av_len(subp) + 2);
	    ht = sat_calloc(hm + 1, sizeof(*ht));
	    subpacks = sat_calloc(av_len(subp) + 2, sizeof(char *));
	    for (j = 0; j <= av_len(subp); j++)
	      {
		SV **svp = av_fetch(subp, j, 0);
		if (!svp)
		  continue;
		s = SvPV_nolen(*svp);
		h = strhash(s) & hm;
		hh = HASHCHAIN_START;
		while ((id = ht[h]) != 0)
		  h = HASHCHAIN_NEXT(h, hh, hm);
		ht[h] = j + 1;
		subpacks[j + 1] = s;
	      }

	    lines = sat_calloc(items - 1, sizeof(*lines));
	    nlines = items - 1;
	    /* lines are of the form "md5sum  pkg/pkg..." */
	    for (i = 0, lp = lines; i < nlines; i++, lp++)
	      {
		s = SvPV_nolen(ST(i + 1));
		if (strlen(s) < 35 || s[32] != ' ' || s[33] != ' ')
		  croak("gen_meta: bad line %s\n", s);
		/* count '/' */
		lp->l = s;
		ns = 0;
		cycle = 0;
		lo = s + 34;
		for (s2 = lo; *s2; s2++)
		  if (*s2 == '/')
		    {
		      if (!cycle)	
			{
			  *s2 = 0;
			  h = strhash(lo) & hm;
			  hh = HASHCHAIN_START;
			  while ((id = ht[h]) != 0)
			    {
			      if (!strcmp(lo, subpacks[id]))
				break;
			      h = HASHCHAIN_NEXT(h, hh, hm);
			    }
			  *s2 = '/';
			  if (id)
			    cycle = 1 + ns;
			}
		      ns++;
		      lo = s2 + 1;
		    }
		if (!cycle)
		  {
		    h = strhash(lo) & hm;
		    hh = HASHCHAIN_START;
		    while ((id = ht[h]) != 0)
		      {
		        if (!strcmp(lo, subpacks[id]))
			  break;
		        h = HASHCHAIN_NEXT(h, hh, hm);
		      }
		    if (id)
		      cycle = 1 + ns;
		  }
		if (cycle)
		  {
		    lp->killed = 1;
		    if (cycle > 1)	/* ignore self cycles */
		      queue_push(&cycles, i);
		  }
		lp->nslash = ns;
		lp->lastoff = lo - s;
	      }
	    sat_free(ht);
	    sat_free(subpacks);

	    /* if we found cycles, prune em */
	    if (cycles.count)
	      {
		char *cycledata = 0;
		int cycledatalen = 0;

		cycledata = sat_extend(cycledata, cycledatalen, 1, 1, 255);
		cycledata[0] = 0;
		cycledatalen += 1;
		hm = mkmask(cycles.count);
		ht = sat_calloc(hm + 1, sizeof(*ht));
		for (i = 0; i < cycles.count; i++)
		  {
		    char *se;
		    s = lines[cycles.elements[i]].l + 34;
		    se = strchr(s, '/');
		    if (se)
		      *se = 0;
		    h = strhash(s) & hm;
		    hh = HASHCHAIN_START;
		    while ((id = ht[h]) != 0)
		      {
		        if (!strcmp(s, cycledata + id))
			  break;
		        h = HASHCHAIN_NEXT(h, hh, hm);
		      }
		    if (id)
		      continue;
		    cycledata = sat_extend(cycledata, cycledatalen, strlen(s) + 1, 1, 255);
		    ht[h] = cycledatalen;
		    strcpy(cycledata + cycledatalen, s);
		    cycledatalen += strlen(s) + 1;
		    if (se)
		      *se = '/';
		  }
		for (i = 0, lp = lines; i < nlines; i++, lp++)
		  {
		    if (lp->killed || !lp->nslash)
		      continue;
		    lo = strchr(lp->l + 34, '/') + 1;
		    for (s2 = lo; *s2; s2++)
		      if (*s2 == '/')
			{
			  *s2 = 0;
			  h = strhash(lo) & hm;
			  hh = HASHCHAIN_START;
			  while ((id = ht[h]) != 0)
			    {
			      if (!strcmp(lo, cycledata + id))
				break;
			      h = HASHCHAIN_NEXT(h, hh, hm);
			    }
			  *s2 = '/';
			  if (id)
			    {
			      lp->killed = 1;
			      break;
			    }
			  lo = s2 + 1;
			}
		    if (lp->killed)
		      continue;
		    h = strhash(lo) & hm;
		    hh = HASHCHAIN_START;
		    while ((id = ht[h]) != 0)
		      {
		        if (!strcmp(lo, cycledata + id))
			  break;
		        h = HASHCHAIN_NEXT(h, hh, hm);
		      }
		    if (id)
		      {
		        lp->killed = 1;
		      }
		  }
		sat_free(ht);
		cycledata = sat_free(cycledata);
		queue_free(&cycles);
	      }

	    /* cycles are pruned, now sort array */
	    if (nlines > 1)
	      qsort(lines, nlines, sizeof(*lines), metacmp);

	    hm = mkmask(nlines);
	    ht = sat_calloc(hm + 1, sizeof(*ht));
	    for (i = 0, lp = lines; i < nlines; i++, lp++)
	      {
		if (lp->killed)
		  continue;
		s = lp->l;
		h = strnhash(s, 10);
		h = strhash_cont(s + lp->lastoff, h) & hm;
	        hh = HASHCHAIN_START;
		while ((id = ht[h]) != 0)
		  {
		    struct metaline *lp2 = lines + (id - 1);
		    if (!strncmp(lp->l, lp2->l, 32) && !strcmp(lp->l + lp->lastoff, lp2->l + lp2->lastoff))
		      break;
		    h = HASHCHAIN_NEXT(h, hh, hm);
		  }
		if (id)
		  lp->killed = 1;
		else
		  ht[h] = i + 1;
	      }
	    sat_free(ht);
	    j = 0;
	    for (i = 0, lp = lines; i < nlines; i++, lp++)
	      if (!lp->killed)
		j++;
	    EXTEND(SP, j);
	    for (i = 0, lp = lines; i < nlines; i++, lp++)
	      {
		SV *sv;
		if (lp->killed)
		  continue;
		sv = newSVpv(lp->l, 0);
		PUSHs(sv_2mortal(sv));
	      }
	    sat_free(lines);
	}

MODULE = BSSolv		PACKAGE = BSSolv::pool		PREFIX = pool

PROTOTYPES: ENABLE

BSSolv::pool
new(packname = "BSSolv::pool")
    char *packname;
    CODE:
	{
	    Pool *pool = pool_create();
	    pool_setdisttype(pool, DISTTYPE_RPM);
	    buildservice_id = str2id(pool, "buildservice:id", 1);
	    buildservice_repocookie= str2id(pool, "buildservice:repocookie", 1);
	    buildservice_external = str2id(pool, "buildservice:external", 1);
	    pool_freeidhashes(pool);
	    printf("Created pool %p\n", pool);fflush(stdout);
	    RETVAL = pool;
	}
    OUTPUT:
	RETVAL
    
void
settype(BSSolv::pool pool, char *type)
    CODE:
	if (!strcmp(type, "rpm"))
	  pool_setdisttype(pool, DISTTYPE_RPM);
	else if (!strcmp(type, "deb"))
	  pool_setdisttype(pool, DISTTYPE_DEB);
	else
	  croak("settype: unknown type '%s'\n", type);


BSSolv::repo
repofromfile(BSSolv::pool pool, char *name, char *filename)
    CODE:
	FILE *fp;
	fp = fopen(filename, "r");
	if (!fp) {
	    croak("%s: %s\n", filename, Strerror(errno));
	    XSRETURN_UNDEF;
	}
	RETVAL = repo_create(pool, name);
	repo_add_solv(RETVAL, fp);
	fclose(fp);
    OUTPUT:
	RETVAL

BSSolv::repo
repofromstr(BSSolv::pool pool, char *name, SV *sv)
    CODE:
	FILE *fp;
	STRLEN len;
	char *buf;
	buf = SvPV(sv, len);
	if (!buf)
	    croak("repofromstr: undef string\n");
	fp = fmemopen(buf, len, "r");
	if (!fp) {
	    croak("fmemopen failed\n");
	    XSRETURN_UNDEF;
	}
	RETVAL = repo_create(pool, name);
	repo_add_solv(RETVAL, fp);
	fclose(fp);
    OUTPUT:
	RETVAL

BSSolv::repo
repofrombins(BSSolv::pool pool, char *name, char *dir, ...)
    CODE:
	{
	    int i;
	    Repo *repo;
	    Repodata *data;
	    repo = repo_create(pool, name);
	    data = repo_add_repodata(repo, 0);
	    for (i = 3; i + 1 < items; i += 2)
	      {
		STRLEN sl;
		char *path;
		char *s = SvPV(ST(i), sl);
		char *sid = SvPV_nolen(ST(i + 1));
		if (sl < 4)
		  continue;
		if (strcmp(s + sl - 4, ".rpm") && strcmp(s + sl - 4, ".deb"))
		  continue;
		if (sl > 10 && !strcmp(s + sl - 10, ".patch.rpm"))
		  continue;
		if (sl > 10 && !strcmp(s + sl - 10, ".nosrc.rpm"))
		  continue;
		if (sl > 8 && !strcmp(s + sl - 8, ".src.rpm"))
		  continue;
		path = sat_dupjoin(dir, "/", s);
		repodata_addbin(data, path, s, (int)sl, sid);
		free(path);
	      }
	    repo_set_str(repo, SOLVID_META, buildservice_repocookie, REPOCOOKIE);
	    repo_internalize(repo);
	    RETVAL = repo;
	}
    OUTPUT:
	RETVAL

BSSolv::repo
repofromdata(BSSolv::pool pool, char *name, HV *rhv)
    CODE:
	{
	    Repo *repo;
	    Repodata *data;
	    SV *sv;
	    HV *hv;
	    AV *av;
	    int i;
	    char *str, *key;
	    I32 keyl;
	    Id p;
	    Solvable *s;

	    repo = repo_create(pool, name);
	    data = repo_add_repodata(repo, 0);
	    hv_iterinit(rhv);
	    while ((sv = hv_iternextsv(rhv, &key, &keyl)) != 0)
	      {
		if (!SvROK(sv) || SvTYPE(SvRV(sv)) != SVt_PVHV)
		  continue;
		hv = (HV *)SvRV(sv);
		str = hvlookupstr(hv, "name", 4);
		if (!str)
		  continue;	/* need to have a name */
		p = repo_add_solvable(repo);
		s = pool_id2solvable(pool, p);
		s->name = str2id(pool, str, 1);
		str = hvlookupstr(hv, "arch", 4);
		if (!str)
		  str = "";	/* dummy, need to have arch */
	        s->arch = str2id(pool, str, 1);
		s->evr = makeevr(pool, hvlookupstr(hv, "epoch", 5), hvlookupstr(hv, "version", 7), hvlookupstr(hv, "release", 7));
		str = hvlookupstr(hv, "path", 4);
		if (str)
		  {
		    char *ss = strrchr(str, '/');
		    if (ss)
		      {
			*ss = 0;
			repodata_set_str(data, p, SOLVABLE_MEDIADIR, str);
			*ss++ = '/';
		      }
		    else
		      ss = str;
		    repodata_set_str(data, p, SOLVABLE_MEDIAFILE, ss);
		  }
		str = hvlookupstr(hv, "id", 2);
		if (str)
		  repodata_set_str(data, p, buildservice_id, str);
		str = hvlookupstr(hv, "source", 6);
		if (str)
		  repodata_set_poolstr(data, p, SOLVABLE_SOURCENAME, str);
		str = hvlookupstr(hv, "hdrmd5", 6);
		if (str && strlen(str) == 32)
		  repodata_set_checksum(data, p, SOLVABLE_PKGID, REPOKEY_TYPE_MD5, str);
		av = hvlookupav(hv, "provides", 8);
		if (av)
		  {
		    for (i = 0; i <= av_len(av); i++)
		      {
			str = avlookupstr(av, i);
			if (str)
			  s->provides = repo_addid_dep(repo, s->provides, dep2id(pool, str), 0);
		      }
		  }
		av = hvlookupav(hv, "requires", 8);
		if (av)
		  {
		    for (i = 0; i <= av_len(av); i++)
		      {
			str = avlookupstr(av, i);
			if (str)
			  s->requires = repo_addid_dep(repo, s->requires, dep2id(pool, str), 0);
		      }
		  }
		if (!s->evr && s->provides)
		  {
		    /* look for self provides */
		    Id pro, *prop = s->repo->idarraydata + s->provides;
		    while ((pro = *prop++) != 0)
		      {
		        Reldep *rd;
			if (!ISRELDEP(pro))
			  continue;
		        rd = GETRELDEP(pool, pro);
			if (rd->name == s->name && rd->flags == REL_EQ)
			  s->evr = rd->evr;
		      }
		  }
		if (s->evr)
		  s->provides = repo_addid_dep(repo, s->provides, rel2id(pool, s->name, s->evr, REL_EQ, 1), 0);
	      }
	    repodata_set_str(data, SOLVID_META, buildservice_repocookie, REPOCOOKIE);
	    if (name && !strcmp(name, "/external/"))
	      repodata_set_void(data, SOLVID_META, buildservice_external);
	    repo_internalize(repo);
	    RETVAL = repo;
	}
    OUTPUT:
	RETVAL

void
createwhatprovides(BSSolv::pool pool)
    CODE:
	if (pool->considered)
	  {
	    map_free(pool->considered);
	    sat_free(pool->considered);
	  }
	pool->considered = sat_calloc(sizeof(Map), 1);
	create_considered(pool, 0, pool->considered);
	pool_createwhatprovides(pool);

void
setdebuglevel(BSSolv::pool pool, int level)
    CODE:
	pool_setdebuglevel(pool, level);

AV *
whatprovides(BSSolv::pool pool, char *str)
    CODE:
	{
	    Id p, pp, id;
	    RETVAL = newAV();
	    sv_2mortal((SV*)RETVAL);
	    id = str2id(pool, str, 0);
	    if (id)
	      FOR_PROVIDES(p, pp, id)
		{
		  SV *reposv = newSV(0);
		  sv_setref_pv(reposv, "BSSolv::repo", (void *)pool->solvables[p].repo);
	          av_push(RETVAL, reposv);
	          av_push(RETVAL, newSViv(p));
		}
	}
    OUTPUT:
	RETVAL

void
consideredpackages(BSSolv::pool pool)
    PPCODE:
	{
	    int p, nsolv = 0;
	    for (p = 2; p < pool->nsolvables; p++)
	      if (MAPTST(pool->considered, p))
		nsolv++;
	    EXTEND(SP, nsolv);
	    for (p = 2; p < pool->nsolvables; p++)
	      if (MAPTST(pool->considered, p))
		PUSHs(sv_2mortal(newSViv((IV)p)));
	}
	

const char *
pkg2name(BSSolv::pool pool, int p)
    CODE:
	RETVAL = id2str(pool, pool->solvables[p].name);
    OUTPUT:
	RETVAL

const char *
pkg2srcname(BSSolv::pool pool, int p)
    CODE:
	if (solvable_lookup_void(pool->solvables + p, SOLVABLE_SOURCENAME))
	  RETVAL = id2str(pool, pool->solvables[p].name);
	else
	  RETVAL = solvable_lookup_str(pool->solvables + p, SOLVABLE_SOURCENAME);
    OUTPUT:
	RETVAL

const char *
pkg2pkgid(BSSolv::pool pool, int p)
    CODE:
	{
	    Id type;
	    const char *s = solvable_lookup_checksum(pool->solvables + p, SOLVABLE_PKGID, &type);
	    RETVAL = s;
	}
    OUTPUT:
	RETVAL

const char *
pkg2bsid(BSSolv::pool pool, int p)
    CODE:
	RETVAL = solvable_lookup_str(pool->solvables + p, buildservice_id);
    OUTPUT:
	RETVAL

const char *
pkg2reponame(BSSolv::pool pool, int p)
    CODE:
	{
	    Repo *repo = pool->solvables[p].repo;
	    RETVAL = repo ? repo->name : 0;
	}
    OUTPUT:
	RETVAL

const char *
pkg2path(BSSolv::pool pool, int p)
    CODE:
	{
	    unsigned int medianr;
	    RETVAL = solvable_get_location(pool->solvables + p, &medianr);
	}
    OUTPUT:
	RETVAL
	
const char *
pkg2fullpath(BSSolv::pool pool, int p, char *myarch)
    CODE:
	{
	    unsigned int medianr;
	    const char *s = solvable_get_location(pool->solvables + p, &medianr);
	    Repo *repo = pool->solvables[p].repo;
	    s = pool_tmpjoin(pool, myarch, "/:full/", s);
	    RETVAL = pool_tmpjoin(pool, repo->name, "/", s);
	}
    OUTPUT:
	RETVAL

HV *
pkg2data(BSSolv::pool pool, int p)
    CODE:
	{
	    Solvable *s = pool->solvables + p;
	    AV *av;
	    Id id;
	    const char *ss, *se;
	    unsigned int medianr;

	    if (!s->repo)
		XSRETURN_EMPTY;
	    RETVAL = newHV();
	    sv_2mortal((SV*)RETVAL);
	    (void)hv_store(RETVAL, "name", 4, newSVpv(id2str(pool, s->name), 0), 0);
	    ss = id2str(pool, s->evr);
	    se = ss;
	    while (*se >= '0' && *se <= '9')
	      se++;
	    if (se != ss && *se == ':' && se[1])
	      {
		(void)hv_store(RETVAL, "epoch", 5, newSVpvn(ss, se - ss), 0);
		ss = se + 1;
	      }
	    se = strrchr(ss, '-');
	    if (se)
	      {
	        (void)hv_store(RETVAL, "version", 7, newSVpvn(ss, se - ss), 0);
	        (void)hv_store(RETVAL, "release", 7, newSVpv(se + 1, 0), 0);
	      }
	    else
	      (void)hv_store(RETVAL, "version", 7, newSVpv(ss, 0), 0);
	    (void)hv_store(RETVAL, "arch", 4, newSVpv(id2str(pool, s->arch), 0), 0);
	    av = newAV();
	    if (s->provides)
	      {
		Id *pp = s->repo->idarraydata + s->provides;
		while ((id = *pp++))
		  {
		    if (id == SOLVABLE_FILEMARKER)
		      break;
		    av_push(av, newSVpv(dep2str(pool, id), 0));
		  }
	      }
	    (void)hv_store(RETVAL, "provides", 8, newRV_inc((SV*)av), 0);
	    av = newAV();
	    if (s->requires)
	      {
		Id *pp = s->repo->idarraydata + s->requires;
		while ((id = *pp++))
		  {
		    if (id == SOLVABLE_PREREQMARKER)
		      continue;
		    ss = dep2str(pool, id);
		    if (*ss == '/')
		      continue;
		    if (*ss == 'r' && !strncmp(ss, "rpmlib(", 7))
		      continue;
		    av_push(av, newSVpv(ss, 0));
		  }
	      }
	    if (solvable_lookup_void(s, SOLVABLE_SOURCENAME))
	      ss = id2str(pool, s->name);
	    else
	      ss = solvable_lookup_str(s, SOLVABLE_SOURCENAME);
	    if (ss)
	      (void)hv_store(RETVAL, "source", 6, newSVpv(ss, 0), 0);
	    (void)hv_store(RETVAL, "requires", 8, newRV_inc((SV*)av), 0);
	    ss = solvable_get_location(s, &medianr);
	    if (ss)
	      (void)hv_store(RETVAL, "path", 4, newSVpv(ss, 0), 0);
	    ss = solvable_lookup_checksum(s, SOLVABLE_PKGID, &id);
	    if (ss && id == REPOKEY_TYPE_MD5)
	      (void)hv_store(RETVAL, "hdrmd5", 6, newSVpv(ss, 0), 0);
	    ss = solvable_lookup_str(s, buildservice_id);
	    if (ss)
	      (void)hv_store(RETVAL, "id", 2, newSVpv(ss, 0), 0);
	}
    OUTPUT:
	RETVAL

void
repos(BSSolv::pool pool)
    PPCODE:
	{
	    int ridx;
	    Repo *repo;

	    EXTEND(SP, pool->nrepos);
	    FOR_REPOS(ridx, repo)
	      {
		SV *sv = sv_newmortal();
		sv_setref_pv(sv, "BSSolv::repo", (void *)repo);
		PUSHs(sv);
	      }
	}

void
DESTROY(BSSolv::pool pool)
    CODE:
	printf("Goodbye pool %p\n", pool);fflush(stdout);
        if (pool->considered)
	  {
	    map_free(pool->considered);
	    pool->considered = sat_free(pool->considered);
	  }
	pool_free(pool);




MODULE = BSSolv		PACKAGE = BSSolv::repo		PREFIX = repo

void
pkgnames(BSSolv::repo repo)
    PPCODE:
	{
	    Pool *pool = repo->pool;
	    Id p;
	    Solvable *s;
	    Map c;
	
	    create_considered(pool, repo, &c);
	    EXTEND(SP, 2 * repo->nsolvables);
	    FOR_REPO_SOLVABLES(repo, p, s)
	      {
		if (!MAPTST(&c, p))
		  continue;
		PUSHs(sv_2mortal(newSVpv(id2str(pool, s->name), 0)));
		PUSHs(sv_2mortal(newSViv(p)));
	      }
	    map_free(&c);
	}


void
tofile(BSSolv::repo repo, char *filename)
    CODE:
	{
	    FILE *fp;
	    fp = fopen(filename, "w");
	    if (fp == 0)
	      croak("%s: %s\n", filename, Strerror(errno));
	    repo_write(repo, fp, myrepowritefilter, 0, 0);
	    if (fclose(fp))
	      croak("fclose: %s\n",  Strerror(errno));
	}

SV *
tostr(BSSolv::repo repo)
    CODE:
	{
	    FILE *fp;
	    char *buf;
	    size_t len;
	    fp = open_memstream(&buf, &len);
	    if (fp == 0)
	      croak("open_memstream: %s\n", Strerror(errno));
	    repo_write(repo, fp, myrepowritefilter, 0, 0);
	    if (fclose(fp))
	      croak("fclose: %s\n",  Strerror(errno));
	    RETVAL = newSVpvn(buf, len);
	    free(buf);
	}
    OUTPUT:
	RETVAL

int
updatefrombins(BSSolv::repo repo, char *dir, ...)
    CODE:
	{
	    Pool *pool = repo->pool;
	    int i;
	    Repodata *data = 0;
	    Hashmask hm;
	    Hashtable ht;
	    Hashval h, hh;
	    int dirty = 0;
	    Map reused;
	    int oldend = 0;
	    Id p, id;
	    Solvable *s;
	    STRLEN sl;
	    char *path;
	    const char *oldcookie;
	  
	    map_init(&reused, repo->end - repo->start);
	    hm = mkmask(2 * repo->nsolvables + 1);
	    ht = sat_calloc(hm + 1, sizeof(*ht));
	    oldcookie = repo_lookup_str(repo, SOLVID_META, buildservice_repocookie);
	    if (oldcookie && !strcmp(oldcookie, REPOCOOKIE))
	      {
		FOR_REPO_SOLVABLES(repo, p, s)
		  {
		    const char *str = solvable_lookup_str(s, buildservice_id);
		    if (!str)
		      continue;
		    h = strhash(str) & hm;
		    hh = HASHCHAIN_START;
		    while ((id = ht[h]) != 0)
		      h = HASHCHAIN_NEXT(h, hh, hm);
		    ht[h] = p;
		  }
	      }
	    if (repo->end != repo->start)
	      oldend = repo->end;

	    for (i = 2; i + 1 < items; i += 2)
	      {
		char *s = SvPV(ST(i), sl);
		char *sid = SvPV_nolen(ST(i + 1));
		if (sl < 4)
		  continue;
		if (strcmp(s + sl - 4, ".rpm") && strcmp(s + sl - 4, ".deb"))
		  continue;
		if (sl > 10 && !strcmp(s + sl - 10, ".patch.rpm"))
		  continue;
		if (sl > 10 && !strcmp(s + sl - 10, ".nosrc.rpm"))
		  continue;
		if (sl > 8 && !strcmp(s + sl - 8, ".src.rpm"))
		  continue;
		path = sat_dupjoin(dir, "/", s);
		h = strhash(sid) & hm;
		hh = HASHCHAIN_START;
		while ((id = ht[h]) != 0)
		  {
		    const char *str = solvable_lookup_str(pool->solvables + id, buildservice_id);
		    if (!strcmp(str, sid))
		      {
			/* check location */
			unsigned int medianr;
			str = solvable_get_location(pool->solvables + id, &medianr);
			if (str[0] == '.' && str[1] == '/')
			  str += 2;
			if (!strcmp(str, s))
		          break;
		      }
		    h = HASHCHAIN_NEXT(h, hh, hm);
		  }
		if (id)
		  {
		    /* same id and location, reuse old entry */
		    MAPSET(&reused, id - repo->start);
		  }
		else
		  {
		    /* add new entry */
		    dirty++;
		    if (!data)
		      data = repo_add_repodata(repo, 0);
		    repodata_addbin(data, path, s, (int)sl, sid);
		  }
		free(path);
	      }
	    if (oldcookie)
	      {
		if (strcmp(oldcookie, REPOCOOKIE))
		  {
		    if (data && data != repo->repodata)
		      repodata_internalize(data);
		    data = repo->repodata;
		    repodata_set_str(data, SOLVID_META, buildservice_repocookie, REPOCOOKIE);
		  }
	      }
	    else
	      {
	        if (!data)
	          data = repo_add_repodata(repo, 0);
	        repodata_set_str(data, SOLVID_META, buildservice_repocookie, REPOCOOKIE);
	      }
	    if (data)
	      repodata_internalize(data);
	    if (oldend)
	      {
		for (i = repo->start; i < oldend; i++)
		  {
		    if (pool->solvables[i].repo != repo)
		      continue;
		    if (MAPTST(&reused, i - repo->start))
		      continue;
		    if (dirty <= 0)
		      dirty--;
		    repo_free_solvable_block(repo, i, 1, 0);
		  }
	      }
	  RETVAL = dirty;
	}
    OUTPUT:
	RETVAL


void
getpathid(BSSolv::repo repo)
    PPCODE:
	{
	    Id p;
	    Solvable *s;
	    EXTEND(SP, repo->nsolvables * 2);
	    FOR_REPO_SOLVABLES(repo, p, s)
	      {
		unsigned int medianr;
		const char *str;
		str = solvable_get_location(s, &medianr);
		PUSHs(sv_2mortal(newSVpv(str, 0)));
		str = solvable_lookup_str(s, buildservice_id);
		PUSHs(sv_2mortal(newSVpv(str, 0)));
	      }
	}

const char *
name(BSSolv::repo repo)
    CODE:
	RETVAL = repo->name;
    OUTPUT:
	RETVAL

int
isexternal(BSSolv::repo repo)
    CODE:
	RETVAL = repo_lookup_void(repo, SOLVID_META, buildservice_external) ? 1 : 0;
    OUTPUT:
	RETVAL





MODULE = BSSolv		PACKAGE = BSSolv::expander	PREFIX = expander


BSSolv::expander
new(char *packname = "BSSolv::expander", BSSolv::pool pool, HV *config)
    CODE:
	{
	    SV *sv, **svp;
	    char *str;
	    int i, neg;
	    Id id, id2;
	    Expander *xp;

	    xp = calloc(sizeof(Expander), 1);
	    xp->pool = pool;
	    svp = hv_fetch(config, "prefer", 6, 0);
	    sv = svp ? *svp : 0;
	    if (sv && SvROK(sv) && SvTYPE(SvRV(sv)) == SVt_PVAV)
	      {
		AV *av = (AV *)SvRV(sv);
		for (i = 0; i <= av_len(av); i++)
		  {
		    svp = av_fetch(av, i, 0);
		    if (!svp)
		      continue;
		    sv = *svp;
		    str = SvPV_nolen(sv);
		    if (!str)
		      continue;
		    neg = 0;
		    if (*str == '-')
		      {
			neg = 1;
			str++;
		      }
		    id = str2id(pool, str, 1);
		    id2 = 0;
		    if ((str = strchr(str, ':')) != 0)
		      id2 = str2id(pool, str + 1, 1);
		    if (neg)
		      {
			MAPEXP(&xp->preferneg, id);
			MAPSET(&xp->preferneg, id);
		        if (id2)
			  {
			    MAPEXP(&xp->prefernegx, id2);
			    MAPSET(&xp->prefernegx, id2);
			  }
		      }
		    else
		      {
			queue_push(&xp->preferposq, id);
			MAPEXP(&xp->preferpos, id);
			MAPSET(&xp->preferpos, id);
		        if (id2)
			  {
			    MAPEXP(&xp->preferposx, id2);
			    MAPSET(&xp->preferposx, id2);
			  }
		      }
		  }
	      }
	    svp = hv_fetch(config, "ignoreh", 7, 0);
	    sv = svp ? *svp : 0;
	    if (sv && SvROK(sv) && SvTYPE(SvRV(sv)) == SVt_PVHV)
	      {
		HV *hv = (HV *)SvRV(sv);
		HE *he;

		hv_iterinit(hv);
		while ((he = hv_iternext(hv)) != 0)
		  {
		    I32 strl;
		    str = hv_iterkey(he, &strl);
		    if (!str)
		      continue;
		 
		    id = str2id(pool, str, 1);
		    id2 = 0;
		    if ((str = strchr(str, ':')) != 0)
		      id2 = str2id(pool, str + 1, 1);
		    MAPEXP(&xp->ignored, id);
		    MAPSET(&xp->ignored, id);
		    if (id2)
		      {
			MAPEXP(&xp->ignoredx, id2);
		        MAPSET(&xp->ignoredx, id2);
		      }
		  }
	      }
	    svp = hv_fetch(config, "conflict", 8, 0);
	    sv = svp ? *svp : 0;
	    if (sv && SvROK(sv) && SvTYPE(SvRV(sv)) == SVt_PVAV)
	      {
		AV *av = (AV *)SvRV(sv);
		for (i = 0; i <= av_len(av); i++)
		  {
		    char *p;
		    Id id2;

		    svp = av_fetch(av, i, 0);
		    if (!svp)
		      continue;
		    sv = *svp;
		    str = SvPV_nolen(sv);
		    if (!str)
		      continue;
		    p = strchr(str, ':');
		    if (!p)
		      continue;
		    id = strn2id(pool, str, p - str, 1);
		    str = p + 1;
		    while ((p = strchr(str, ',')) != 0)
		      {
			id2 = strn2id(pool, str, p - str, 1);
			queue_push2(&xp->conflictsq, id, id2);
			MAPEXP(&xp->conflicts, id);
			MAPSET(&xp->conflicts, id);
			MAPEXP(&xp->conflicts, id2);
			MAPSET(&xp->conflicts, id2);
			str = p + 1;
		      }
		    id2 = str2id(pool, str, 1);
		    queue_push2(&xp->conflictsq, id, id2);
		    MAPEXP(&xp->conflicts, id);
		    MAPSET(&xp->conflicts, id);
		    MAPEXP(&xp->conflicts, id2);
		    MAPSET(&xp->conflicts, id2);
		  }
	      }
	    sv = get_sv("Build::expand_dbg", FALSE);
	    if (sv && SvTRUE(sv))
	      xp->debug = 1;
	    printf("Created expander %p\n", xp);fflush(stdout);
	    RETVAL = xp;
	}
    OUTPUT:
	RETVAL


void
expand(BSSolv::expander xp, ...)
    PPCODE:
	{
	    Pool *pool;
	    int i, nerrors;
	    Id id, who;
	    Queue revertignore, in, out;

	    queue_init(&revertignore);
	    queue_init(&in);
	    queue_init(&out);
	    pool = xp->pool;
	    for (i = 1; i < items; i++)
	      {
		char *s = SvPV_nolen(ST(i));
		if (*s == '-')
		  {
		    Id id = str2id(pool, s + 1, 1);
		    MAPEXP(&xp->ignored, id);
		    if (MAPTST(&xp->ignored, id))
		      continue;
		    MAPSET(&xp->ignored, id);
		    queue_push(&revertignore, id);
		    if ((s = strchr(s + 1, ':')) != 0)
		      {
			id = str2id(pool, s + 1, 1);
			MAPEXP(&xp->ignored, id);
			if (MAPTST(&xp->ignoredx, id))
			  continue;
			MAPSET(&xp->ignoredx, id);
			queue_push(&revertignore, -id);
		      }
		  }
		else
		  {
		    Id id = dep2id(pool, s);
		    queue_push(&in, id);
		  }
	      }

	    MAPEXP(&xp->ignored, pool->ss.nstrings);
	    MAPEXP(&xp->ignoredx, pool->ss.nstrings);
	    MAPEXP(&xp->preferpos, pool->ss.nstrings);
	    MAPEXP(&xp->preferposx, pool->ss.nstrings);
	    MAPEXP(&xp->preferneg, pool->ss.nstrings);
	    MAPEXP(&xp->prefernegx, pool->ss.nstrings);
	    MAPEXP(&xp->conflicts, pool->ss.nstrings);

	    nerrors = expander_expand(xp, &in, &out);

	    /* revert ignores */
	    for (i = 0; i < revertignore.count; i++)
	      {
		id = revertignore.elements[i];
		if (id > 0)
		  MAPCLR(&xp->ignored, id);
		else
		  MAPCLR(&xp->ignoredx, -id);
	      }

	    if (nerrors)
	      {
		EXTEND(SP, nerrors + 1);
		PUSHs(sv_2mortal(newSV(0)));
		for (i = 0; i < out.count; )
		  {
		    SV *sv;
		    Id type = out.elements[i];
		    if (type == ERROR_NOPROVIDER)
		      {
			id = out.elements[i + 1];
			who = out.elements[i + 2];
			if (who)
		          sv = newSVpvf("nothing provides %s needed by %s", dep2str(pool, id), id2str(pool, pool->solvables[who].name));
			else
		          sv = newSVpvf("nothing provides %s", dep2str(pool, id));
			i += 3;
		      }
		    else if (type == ERROR_CHOICE)
		      {
			int j;
			char *str = "";
			for (j = i + 3; out.elements[j]; j++)
			  {
			    Solvable *s = pool->solvables + out.elements[j];
			    str = pool_tmpjoin(pool, str, " ", id2str(pool, s->name));
			  }
			if (*str)
			  str++;	/* skip starting ' ' */
			id = out.elements[i + 1];
			who = out.elements[i + 2];
			if (who)
		          sv = newSVpvf("have choice for %s needed by %s: %s", dep2str(pool, id), id2str(pool, pool->solvables[who].name), str);
			else
		          sv = newSVpvf("have choice for %s: %s", dep2str(pool, id), str);
			i = j + 1;
		      }
		    else
		      croak("expander: bad error type\n");
		    PUSHs(sv_2mortal(sv));
		  }
	      }
	    else
	      {
		EXTEND(SP, out.count + 1);
		PUSHs(sv_2mortal(newSViv((IV)1)));
		for (i = 0; i < out.count; i++)
		  {
		    Solvable *s = pool->solvables + out.elements[i];
		    PUSHs(sv_2mortal(newSVpv(id2str(pool, s->name), 0)));
		  }
	      }
	}

void
DESTROY(BSSolv::expander xp)
    CODE:
	printf("Goodbye expander %p\n", xp);fflush(stdout);
	map_free(&xp->ignored);
	map_free(&xp->ignoredx);
	queue_free(&xp->preferposq);
	map_free(&xp->preferpos);
	map_free(&xp->preferposx);
	map_free(&xp->preferneg);
	map_free(&xp->prefernegx);
	queue_free(&xp->conflictsq);
	map_free(&xp->conflicts);
	sat_free(xp);
