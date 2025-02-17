#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <openssl/asn1.h>
#include <openssl/objects.h>
#include <openssl/bio.h>
#include <openssl/crypto.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>
#include <openssl/opensslconf.h>
#ifndef OPENSSL_NO_EC
# include <openssl/ec.h>
#endif

/* from openssl/apps/apps.h */
#define FORMAT_UNDEF    0
#define FORMAT_ASN1     1
#define FORMAT_TEXT     2
#define FORMAT_PEM      3
#define FORMAT_PKCS12   5
#define FORMAT_SMIME    6
#define FORMAT_ENGINE   7
#define FORMAT_IISSGC   8

/* fake our package name */
typedef X509*  Crypt__OpenSSL__X509;
typedef X509_EXTENSION* Crypt__OpenSSL__X509__Extension;
typedef ASN1_OBJECT* Crypt__OpenSSL__X509__ObjectID;
typedef X509_NAME* Crypt__OpenSSL__X509__Name;
typedef X509_NAME_ENTRY* Crypt__OpenSSL__X509__Name_Entry;
typedef X509_CRL* Crypt__OpenSSL__X509__CRL;

/* 1.0 backwards compat */
#if OPENSSL_VERSION_NUMBER < 0x10100000
#define const_ossl11

#ifndef sk_OPENSSL_STRING_num
#define sk_OPENSSL_STRING_num sk_num
#endif

#ifndef sk_OPENSSL_STRING_value
#define sk_OPENSSL_STRING_value sk_value
#endif

static ASN1_INTEGER *X509_get0_serialNumber(const X509 *a)
{
  return a->cert_info->serialNumber;
}

static void RSA_get0_key(const RSA *r,
                         const BIGNUM **n, const BIGNUM **e, const BIGNUM **d)
{
  if (n != NULL)
    *n = r->n;
  if (e != NULL)
    *e = r->e;
  if (d != NULL)
    *d = r->d;
}

static RSA *EVP_PKEY_get0_RSA(EVP_PKEY *pkey)
{
  if (pkey->type != EVP_PKEY_RSA)
    return NULL;
  return pkey->pkey.rsa;
}

static void X509_CRL_get0_signature(const X509_CRL *crl, const ASN1_BIT_STRING **psig,
                                    X509_ALGOR **palg)
{
  if (psig != NULL)
    *psig = crl->signature;
  if (palg != NULL)
    *palg = crl->sig_alg;
}

#if OPENSSL_VERSION_NUMBER < 0x10002000
static void X509_get0_signature(const_ossl11 ASN1_BIT_STRING **psig, const_ossl11 X509_ALGOR **palg,
                                const X509 *x)
{
    if (psig != NULL)
        *psig = x->signature;
    if (palg != NULL)
        *palg = x->sig_alg;
}
#endif

static void DSA_get0_pqg(const DSA *d,
                         const BIGNUM **p, const BIGNUM **q, const BIGNUM **g)
{
  if (p != NULL)
    *p = d->p;
  if (q != NULL)
    *q = d->q;
  if (g != NULL)
    *g = d->g;
}

static void DSA_get0_key(const DSA *d,
                         const BIGNUM **pub_key, const BIGNUM **priv_key)
{
  if (pub_key != NULL)
    *pub_key = d->pub_key;
  if (priv_key != NULL)
    *priv_key = d->priv_key;
}

static DSA *EVP_PKEY_get0_DSA(EVP_PKEY *pkey)
{
  if (pkey->type != EVP_PKEY_DSA)
    return NULL;
  return pkey->pkey.dsa;
}

static EC_KEY *EVP_PKEY_get0_EC_KEY(EVP_PKEY *pkey)
{
  if (pkey->type != EVP_PKEY_EC)
    return NULL;
  return pkey->pkey.ec;
}

#else
#define const_ossl11 const
#endif

/* Unicode 0xfffd */
static U8 utf8_substitute_char[3] = { 0xef, 0xbf, 0xbd };

/* stolen from OpenSSL.xs */
long bio_write_cb(struct bio_st *bm, int m, const char *ptr, int l, long x, long y) {

  if (m == BIO_CB_WRITE) {
    SV *sv = (SV *) BIO_get_callback_arg(bm);
    sv_catpvn(sv, ptr, l);
  }

  if (m == BIO_CB_PUTS) {
    SV *sv = (SV *) BIO_get_callback_arg(bm);
    l = strlen(ptr);
    sv_catpvn(sv, ptr, l);
  }

  return l;
}

static BIO* sv_bio_create(void) {

  SV *sv = newSVpvn("", 0);

  /* create an in-memory BIO abstraction and callbacks */
  BIO *bio = BIO_new(BIO_s_mem());

  BIO_set_callback(bio, bio_write_cb);
  BIO_set_callback_arg(bio, (void *)sv);

  return bio;
}

static SV* sv_bio_final(BIO *bio) {

  SV* sv;

  (void)BIO_flush(bio);
  sv = (SV *)BIO_get_callback_arg(bio);
  BIO_set_callback_arg(bio, (void *)NULL);
  BIO_set_callback(bio, (void *)NULL);
  BIO_free_all(bio);

  if (!sv) sv = &PL_sv_undef;

  return sv;
}

/* call this just before sv_bio_final if the BIO got an UTF8 encoded text and you want native perl utf-8 strings. */
static SV* sv_bio_utf8_on(BIO *bio) {

  SV* sv = (SV *)BIO_get_callback_arg(bio);

  /* Illegal utf-8 in the string */
  if (!sv_utf8_decode(sv)) {
    STRLEN len;
    SV *nsv = newSVpvn("", 0);

    const U8* start = (U8 *) SvPV(sv, len);
    const U8* end   = start + len;
    const U8* cur;

    while ((start < end) && !is_utf8_string_loclen(start, len, &cur, 0)) {
      sv_catpvn(nsv, (const char*)start, (cur - start) + 1);  /* text that was ok */
      sv_catpvn(nsv, (const char*)utf8_substitute_char, 3);  /* insert \x{fffd} */
      start = cur + 1;
      len = end - cur;
    }

    if (start < end) {
      sv_catpvn(nsv, (const char*)start, (cur - start) - 1);  /* rest of the string */
    }

    sv_copypv(sv, nsv);
    SvREFCNT_dec(nsv);
    sv_utf8_decode(sv); /* should be ok now */
  }

  return sv;
}

/*
static void sv_bio_error(BIO *bio) {

  SV* sv = (SV *)BIO_get_callback_arg(bio);
  if (sv) sv_free(sv);

  BIO_free_all (bio);
}
*/

static const char *ssl_error(void) {
  BIO *bio;
  SV *sv;
  STRLEN l;

  bio = sv_bio_create();
  ERR_print_errors(bio);
  sv = sv_bio_final(bio);
  ERR_clear_error();
  return SvPV(sv, l);
}

/* Make a scalar ref to a class object */
static SV* sv_make_ref(const char* class, void* object) {
  SV* rv;

  rv = newSV(0);
  sv_setref_pv(rv, class, (void*) object);

  if (! sv_isa(rv, class) ) {
    croak("Error creating reference to %s", class);
  }

  return rv;
}

/*
 * hash of extensions from x509.
 * no_name can be
 *  0: index by long name,
 *  1: index by oid string,
 *  2: index by short name
*/
static HV* hv_exts(X509* x509, int no_name) {
  X509_EXTENSION *ext;
  int i, c, r;
  size_t len = 128;
  char* key = NULL;
  SV* rv;

  HV* RETVAL = newHV();
  sv_2mortal((SV*)RETVAL);
  c = X509_get_ext_count(x509);

  if ( !(c > 0) ) {
    croak("No extensions found\n");
  }

  for (i = 0; i < c; i++) {
    r = 0;

    ext = X509_get_ext(x509, i);

    if (ext == NULL) croak("Extension %d unavailable\n", i);

    rv = sv_make_ref("Crypt::OpenSSL::X509::Extension", (void*)ext);

    if (no_name == 0 || no_name == 1) {

       key = malloc(sizeof(char) * (len + 1)); /*FIXME will it leak?*/
       r = OBJ_obj2txt(key, len, X509_EXTENSION_get_object(ext), no_name);

    } else if (no_name == 2) {

       key = (char*)OBJ_nid2sn(OBJ_obj2nid(X509_EXTENSION_get_object(ext)));
       r = strlen(key);
    }

    if (! hv_store(RETVAL, key, r, rv, 0) ) croak("Error storing extension in hash\n");
  }

  return RETVAL;
}

MODULE = Crypt::OpenSSL::X509    PACKAGE = Crypt::OpenSSL::X509

PROTOTYPES: DISABLE

BOOT:
{
  HV *stash = gv_stashpvn("Crypt::OpenSSL::X509", 20, TRUE);

  struct { char *n; I32 v; } Crypt__OpenSSL__X509__const[] = {

  {"OPENSSL_VERSION_NUMBER", OPENSSL_VERSION_NUMBER},
  {"FORMAT_UNDEF", FORMAT_UNDEF},
  {"FORMAT_ASN1", FORMAT_ASN1},
  {"FORMAT_TEXT", FORMAT_TEXT},
  {"FORMAT_PEM", FORMAT_PEM},
  {"FORMAT_PKCS12", FORMAT_PKCS12},
  {"FORMAT_SMIME", FORMAT_SMIME},
  {"FORMAT_ENGINE", FORMAT_ENGINE},
  {"FORMAT_IISSGC", FORMAT_IISSGC},
  {"V_ASN1_PRINTABLESTRING",  V_ASN1_PRINTABLESTRING},
  {"V_ASN1_UTF8STRING",  V_ASN1_UTF8STRING},
  {"V_ASN1_IA5STRING",  V_ASN1_IA5STRING},
  {Nullch,0}};

  char *name;
  int i;

  for (i = 0; (name = Crypt__OpenSSL__X509__const[i].n); i++) {
    newCONSTSUB(stash, name, newSViv(Crypt__OpenSSL__X509__const[i].v));
  }

  ERR_load_crypto_strings();
  OPENSSL_add_all_algorithms_conf();
}

Crypt::OpenSSL::X509
new(class)
  SV  *class

  CODE:

  if ((RETVAL = X509_new()) == NULL) {
    croak("X509_new");
  }

  if (!X509_set_version(RETVAL, 2)) {
    X509_free(RETVAL);
    croak ("%s - can't X509_set_version()", SvPV_nolen(class));
  }

  ASN1_INTEGER_set(X509_get_serialNumber(RETVAL), 0L);

  OUTPUT:
  RETVAL

Crypt::OpenSSL::X509
new_from_string(class, string, format = FORMAT_PEM)
  SV  *class
  SV  *string
  int  format

  ALIAS:
  new_from_file = 1

  PREINIT:
  BIO *bio;
  STRLEN len;
  char *cert;

  CODE:

  cert = SvPV(string, len);

  if (ix == 1) {
    bio = BIO_new_file(cert, "r");
  } else {
    bio = BIO_new_mem_buf(cert, len);
  }

  if (!bio) croak("%s: Failed to create BIO", SvPV_nolen(class));

  /* this can come in any number of ways */
  if (format == FORMAT_ASN1) {

    RETVAL = (X509*)d2i_X509_bio(bio, NULL);

  } else {

    RETVAL = (X509*)PEM_read_bio_X509(bio, NULL, NULL, NULL);
  }

  BIO_free_all(bio);

  if (!RETVAL) croak("%s: failed to read X509 certificate.", SvPV_nolen(class));

  OUTPUT:
  RETVAL

void
DESTROY(x509)
  Crypt::OpenSSL::X509 x509;

  PPCODE:

  if (x509) X509_free(x509); x509 = 0;

# This is called via an END block in the Perl module to clean up initialization that happened in BOOT.
void
__X509_cleanup(void)
  PPCODE:

  CRYPTO_cleanup_all_ex_data();
  ERR_free_strings();
#if OPENSSL_VERSION_NUMBER < 0x10100000
  ERR_remove_state(0);
#endif
  EVP_cleanup();

SV*
accessor(x509)
  Crypt::OpenSSL::X509 x509;

  ALIAS:
  subject = 1
  issuer  = 2
  serial  = 3
  hash    = 4
  subject_hash = 4
  notBefore = 5
  notAfter  = 6
  email     = 7
  version   = 8
  sig_alg_name = 9
  key_alg_name = 10
  issuer_hash = 11

  PREINIT:
  BIO *bio;
  X509_NAME *name;

  CODE:

  bio = sv_bio_create();

  /* this includes both subject and issuer since they are so much alike */
  if (ix == 1 || ix == 2) {

    if (ix == 1) {
      name = X509_get_subject_name(x509);
    } else {
      name = X509_get_issuer_name(x509);
    }

    /* this is prefered over X509_NAME_oneline() */
    X509_NAME_print_ex(bio, name, 0, (XN_FLAG_SEP_CPLUS_SPC | ASN1_STRFLGS_UTF8_CONVERT) & ~ASN1_STRFLGS_ESC_MSB);

    /* this need not be pure ascii, try to get a native perl character string with * utf8 */
    sv_bio_utf8_on(bio);

  } else if (ix == 3) {

    i2a_ASN1_INTEGER(bio, X509_get0_serialNumber(x509));

  } else if (ix == 4) {

    BIO_printf(bio, "%08lx", X509_subject_name_hash(x509));

  } else if (ix == 5) {

    ASN1_TIME_print(bio, X509_get_notBefore(x509));

  } else if (ix == 6) {

    ASN1_TIME_print(bio, X509_get_notAfter(x509));

  } else if (ix == 7) {

    int j;
    STACK_OF(OPENSSL_STRING) *emlst = X509_get1_email(x509);

    for (j = 0; j < sk_OPENSSL_STRING_num(emlst); j++) {
      BIO_printf(bio, "%s", sk_OPENSSL_STRING_value(emlst, j));
    }

    X509_email_free(emlst);

  } else if (ix == 8) {

    BIO_printf(bio, "%02ld", X509_get_version(x509));

  } else if (ix == 9) {
    const_ossl11 X509_ALGOR *palg;
    const_ossl11 ASN1_OBJECT *paobj;

    X509_get0_signature(NULL, &palg, x509);
    X509_ALGOR_get0(&paobj, NULL, NULL, palg);

    i2a_ASN1_OBJECT(bio, paobj);
  } else if ( ix == 10 ) {
    X509_PUBKEY *pkey;
    ASN1_OBJECT *ppkalg;

    pkey = X509_get_X509_PUBKEY(x509);
    X509_PUBKEY_get0_param(&ppkalg, NULL, NULL, NULL, pkey);

    i2a_ASN1_OBJECT(bio, ppkalg);
  } else if ( ix == 11 ) {
    BIO_printf(bio, "%08lx", X509_issuer_name_hash(x509));
  }

  RETVAL = sv_bio_final(bio);

  OUTPUT:
  RETVAL

Crypt::OpenSSL::X509::Name
subject_name(x509)
  Crypt::OpenSSL::X509 x509;

  ALIAS:
  subject_name = 1
  issuer_name  = 2

  CODE:
  if (ix == 1) {
    RETVAL = X509_get_subject_name(x509);
  } else {
    RETVAL = X509_get_issuer_name(x509);
  }

  OUTPUT:
  RETVAL

SV*
sig_print(x509)
  Crypt::OpenSSL::X509 x509;

  PREINIT:
  BIO *bio;
  unsigned char *s;
  const_ossl11 ASN1_BIT_STRING *psig;
  int n,i;

  CODE:

  X509_get0_signature(&psig, NULL, x509);
  n   = psig->length;
  s   = psig->data;
  bio = sv_bio_create();

  for (i=0; i<n; i++) {
    BIO_printf(bio, "%02x", s[i]);
  }

  RETVAL = sv_bio_final(bio);
  OUTPUT:
  RETVAL

SV*
as_string(x509, format = FORMAT_PEM)
  Crypt::OpenSSL::X509 x509;
  int format;

  PREINIT:
  BIO *bio;

  CODE:

  bio = sv_bio_create();

  /* get the certificate back out in a specified format. */

  if (format == FORMAT_PEM) {

    PEM_write_bio_X509(bio, x509);

  } else if (format == FORMAT_ASN1) {

    i2d_X509_bio(bio, x509);

  }

  RETVAL = sv_bio_final(bio);

  OUTPUT:
  RETVAL

SV*
bit_length(x509)
  Crypt::OpenSSL::X509 x509;

  PREINIT:
  EVP_PKEY *pkey;
  DSA *dsa_pkey;
  RSA *rsa_pkey;
  EC_KEY *ec_pkey;
  const BIGNUM *p;
  const BIGNUM *n;
  int length;

  CODE:
  pkey = X509_extract_key(x509);
  if (pkey == NULL) {
    EVP_PKEY_free(pkey);
    croak("Public key is unavailable\n");
  }

  switch(EVP_PKEY_base_id(pkey)) {
    case EVP_PKEY_RSA:
      rsa_pkey = EVP_PKEY_get0_RSA(pkey);
      RSA_get0_key(rsa_pkey, &n, NULL, NULL);
      length = BN_num_bits(n);
      break;
    case EVP_PKEY_DSA:
      dsa_pkey = EVP_PKEY_get0_DSA(pkey);
      DSA_get0_pqg(dsa_pkey, &p, NULL, NULL);
      length = BN_num_bits(p);
      break;
#ifndef OPENSSL_NO_EC
    case EVP_PKEY_EC:
    {
      const EC_GROUP *group;
      BIGNUM* ec_order;
      ec_order = BN_new();
      if ( !ec_order ) {
        EVP_PKEY_free(pkey);
        croak("Could not malloc bignum");
      }
      ec_pkey = EVP_PKEY_get0_EC_KEY(pkey);
      if ( (group = EC_KEY_get0_group(ec_pkey)) == NULL) {
        EVP_PKEY_free(pkey);
        croak("No EC group");
      }
      /* */
      if (!EC_GROUP_get_order(group, ec_order, NULL)) {
        EVP_PKEY_free(pkey);
        croak("Could not get ec-group order");
      }
      length = BN_num_bits(ec_order);
      /* */
      BN_free(ec_order);
      break;
    }
#endif
    default:
      EVP_PKEY_free(pkey);
      croak("Unknown public key type");
  }

  RETVAL = newSVuv(length);

  OUTPUT:
  RETVAL

const char*
curve(x509)
  Crypt::OpenSSL::X509 x509;

  PREINIT:
#ifndef OPENSSL_NO_EC
  EVP_PKEY *pkey;
#endif

  CODE:
#ifdef OPENSSL_NO_EC
  if ( x509 ) {} /* fix unused variable warning. */
  croak("OpenSSL without EC-support");
#else
  pkey = X509_extract_key(x509);
  if (pkey == NULL) {
    EVP_PKEY_free(pkey);
    croak("Public key is unavailable\n");
  }
  if ( EVP_PKEY_base_id(pkey) == EVP_PKEY_EC ) {
    const EC_GROUP *group;
    EC_KEY *ec_pkey;
    int nid;
    ec_pkey = EVP_PKEY_get0_EC_KEY(pkey);
    if ( (group = EC_KEY_get0_group(ec_pkey)) == NULL) {
       EVP_PKEY_free(pkey);
       croak("No EC group");
    }
    nid = EC_GROUP_get_curve_name(group);
    if ( nid == 0 ) {
       EVP_PKEY_free(pkey);
       croak("invalid nid");
    }
    RETVAL = OBJ_nid2sn(nid);
  } else {
    EVP_PKEY_free(pkey);
    croak("Wrong Algorithm type\n");
  }
  EVP_PKEY_free(pkey);
#endif

  OUTPUT:
  RETVAL


SV*
modulus(x509)
  Crypt::OpenSSL::X509 x509;

  PREINIT:
  EVP_PKEY *pkey;
  BIO *bio;
  int pkey_id;

  CODE:

  pkey = X509_extract_key(x509);
  bio  = sv_bio_create();

  if (pkey == NULL) {

    BIO_free_all(bio);
    EVP_PKEY_free(pkey);
    croak("Modulus is unavailable\n");
  }

  pkey_id = EVP_PKEY_base_id(pkey);
  if (pkey_id == EVP_PKEY_RSA) {
    RSA *rsa_pkey;
    const BIGNUM *n;

    rsa_pkey = EVP_PKEY_get0_RSA(pkey);
    RSA_get0_key(rsa_pkey, &n, NULL, NULL);

    BN_print(bio, n);

  } else if (pkey_id == EVP_PKEY_DSA) {
    DSA *dsa_pkey;
    const BIGNUM *pub_key;

    dsa_pkey = EVP_PKEY_get0_DSA(pkey);
    DSA_get0_key(dsa_pkey, &pub_key, NULL);
    BN_print(bio, pub_key);
#ifndef OPENSSL_NO_EC
  } else if ( pkey_id == EVP_PKEY_EC ) {
    const EC_POINT *public_key;
    const EC_GROUP *group;
    EC_KEY *ec_pkey;
    BIGNUM  *pub_key=NULL;

    ec_pkey = EVP_PKEY_get0_EC_KEY(pkey);
    if ( (group = EC_KEY_get0_group(ec_pkey)) == NULL) {
       BIO_free_all(bio);
       EVP_PKEY_free(pkey);
       croak("No EC group");
    }
    public_key = EC_KEY_get0_public_key(ec_pkey);
    if ((pub_key = EC_POINT_point2bn(group, public_key, EC_KEY_get_conv_form(ec_pkey), NULL, NULL)) == NULL) {
       BIO_free_all(bio);
       EVP_PKEY_free(pkey);
       croak("EC library error");
    }
    BN_print(bio, pub_key);
#endif
  } else {

    BIO_free_all(bio);
    EVP_PKEY_free(pkey);
    croak("Wrong Algorithm type\n");
  }

  RETVAL = sv_bio_final(bio);

  EVP_PKEY_free(pkey);

  OUTPUT:
  RETVAL

SV*
exponent(x509)
  Crypt::OpenSSL::X509 x509;

  PREINIT:
  EVP_PKEY *pkey;
  BIO *bio;

  ALIAS:
  pub_exponent = 1

  CODE:
  pkey = X509_get_pubkey(x509);
  bio  = sv_bio_create();

  /* Silence warning */
  if (ix)

  if (pkey == NULL) {
    BIO_free_all(bio);
    EVP_PKEY_free(pkey);
    croak("Exponent is unavailable\n");
  }

  if (EVP_PKEY_base_id(pkey) == EVP_PKEY_RSA) {
    RSA *rsa_pkey;
    const BIGNUM *e;

    rsa_pkey = EVP_PKEY_get0_RSA(pkey);
    RSA_get0_key(rsa_pkey, NULL, &e, NULL);

    BN_print(bio, e);
  } else {
    BIO_free_all(bio);
    EVP_PKEY_free(pkey);
    croak("Wrong Algorithm type -- exponent only available with RSA\n");
  }

  RETVAL = sv_bio_final(bio);

  EVP_PKEY_free(pkey);

  OUTPUT:
  RETVAL

SV*
fingerprint_md5(x509)
  Crypt::OpenSSL::X509 x509;

  ALIAS:
  fingerprint_sha1 = 1
  fingerprint_sha224 = 2
  fingerprint_sha256 = 3
  fingerprint_sha384 = 4
  fingerprint_sha512 = 5

  PREINIT:

  const EVP_MD *mds[] = { EVP_md5(), EVP_sha1(), EVP_sha224(), EVP_sha256(), EVP_sha384(), EVP_sha512() };
  unsigned char md[EVP_MAX_MD_SIZE];
  int i;
  unsigned int n;
  BIO *bio;

  CODE:

  bio = sv_bio_create();

  if (!X509_digest(x509, mds[ix], md, &n)) {

    BIO_free_all(bio);
    croak("Digest error: %s", ssl_error());
  }

  BIO_printf(bio, "%02X", md[0]);
  for (i = 1; i < n; i++) {
    BIO_printf(bio, ":%02X", md[i]);
  }

  RETVAL = sv_bio_final(bio);

  OUTPUT:
  RETVAL

SV*
checkend(x509, checkoffset)
  Crypt::OpenSSL::X509 x509;
  IV checkoffset;

  PREINIT:
  time_t now;

  CODE:

  now = time(NULL);

  /* given an offset in seconds, will the certificate be expired? */
  if (ASN1_UTCTIME_cmp_time_t(X509_get_notAfter(x509), now + (int)checkoffset) == -1) {
    RETVAL = &PL_sv_yes;
  } else {
    RETVAL = &PL_sv_no;
  }

  OUTPUT:
  RETVAL

SV*
pubkey(x509)
  Crypt::OpenSSL::X509 x509;

  PREINIT:
  EVP_PKEY *pkey;
  BIO *bio;
  int pkey_id;

  CODE:

  pkey = X509_get_pubkey(x509);
  bio  = sv_bio_create();

  if (pkey == NULL) {

    BIO_free_all(bio);
    EVP_PKEY_free(pkey);
    croak("Public Key is unavailable\n");
  }

  pkey_id = EVP_PKEY_base_id(pkey);
  if (pkey_id == EVP_PKEY_RSA) {
    RSA *rsa_pkey;

    rsa_pkey = EVP_PKEY_get0_RSA(pkey);
    PEM_write_bio_RSAPublicKey(bio, rsa_pkey);

  } else if (pkey_id == EVP_PKEY_DSA) {
    DSA *dsa_pkey;

    dsa_pkey = EVP_PKEY_get0_DSA(pkey);

    PEM_write_bio_DSA_PUBKEY(bio, dsa_pkey);
#ifndef OPENSSL_NO_EC
  } else if (pkey_id == EVP_PKEY_EC ) {
    EC_KEY *ec_pkey;

    ec_pkey = EVP_PKEY_get0_EC_KEY(pkey);
    PEM_write_bio_EC_PUBKEY(bio, ec_pkey);
#endif
  } else {

    BIO_free_all(bio);
    EVP_PKEY_free(pkey);
    croak("Wrong Algorithm type\n");
  }

  EVP_PKEY_free(pkey);

  RETVAL = sv_bio_final(bio);

  OUTPUT:
  RETVAL

char*
pubkey_type(x509)
        Crypt::OpenSSL::X509 x509;
    PREINIT:
        EVP_PKEY *pkey;
	int pkey_id;
    CODE:
        RETVAL=NULL;
        pkey = X509_get_pubkey(x509);

        if(!pkey)
            XSRETURN_UNDEF;

	pkey_id = EVP_PKEY_base_id(pkey);
        if (pkey_id == EVP_PKEY_DSA) {
            RETVAL="dsa";

        } else if (pkey_id == EVP_PKEY_RSA) {
            RETVAL="rsa";
#ifndef OPENSSL_NO_EC
        } else if (pkey_id == EVP_PKEY_EC ) {
            RETVAL="ec";
#endif
        }

    OUTPUT:
    RETVAL

int
num_extensions(x509)
  Crypt::OpenSSL::X509 x509;

  CODE:
  RETVAL = X509_get_ext_count(x509);

  OUTPUT:
  RETVAL

Crypt::OpenSSL::X509::Extension
extension(x509, i)
  Crypt::OpenSSL::X509 x509;
  int i;

  PREINIT:
  X509_EXTENSION *ext;
  int c;

  CODE:
  ext = NULL;

  c = X509_get_ext_count(x509);

  if (!(c > 0)) {
    croak("No extensions found\n");
  } else if (i >= c || i < 0) {
    croak("Requested extension index out of range\n");
  } else {
    ext = X509_get_ext(x509, i);
  }

  if (ext == NULL) {
    /* X509_EXTENSION_free(ext); // not needed? */
    croak("Extension unavailable\n");
  }

  RETVAL = ext;

  OUTPUT:
  RETVAL

HV*
extensions(x509)
  Crypt::OpenSSL::X509 x509

  ALIAS:
  extensions_by_long_name = 0
  extensions_by_oid = 1
  extensions_by_name = 2

  CODE:
  RETVAL = hv_exts(x509, ix);

  OUTPUT:
  RETVAL

MODULE = Crypt::OpenSSL::X509    PACKAGE = Crypt::OpenSSL::X509::Extension

int
critical(ext)
  Crypt::OpenSSL::X509::Extension ext;

  CODE:

  if (ext == NULL) {
    croak("No extension supplied\n");
  }

  RETVAL = X509_EXTENSION_get_critical(ext);

  OUTPUT:
  RETVAL

Crypt::OpenSSL::X509::ObjectID
object(ext)
  Crypt::OpenSSL::X509::Extension ext;

  CODE:

  if (ext == NULL) {
    croak("No extension supplied\n");
  }

  RETVAL = X509_EXTENSION_get_object(ext);

  OUTPUT:
  RETVAL

SV*
value(ext)
  Crypt::OpenSSL::X509::Extension ext;

  PREINIT:
  BIO* bio;

  CODE:
  bio  = sv_bio_create();

  if (ext == NULL) {
    BIO_free_all(bio);
    croak("No extension supplied\n");
  }

  ASN1_STRING_print_ex(bio, X509_EXTENSION_get_data(ext), ASN1_STRFLGS_DUMP_ALL);

  RETVAL = sv_bio_final(bio);

  OUTPUT:
  RETVAL

SV*
to_string(ext)
  Crypt::OpenSSL::X509::Extension ext;

  PREINIT:
  BIO* bio;

  CODE:
  bio = sv_bio_create();

  if (ext == NULL) {
    BIO_free_all(bio);
    croak("No extension supplied\n");
  }

  X509V3_EXT_print(bio, ext, 0, 0);

  RETVAL = sv_bio_final(bio);

  OUTPUT:
  RETVAL

int
basicC(ext, value)
  Crypt::OpenSSL::X509::Extension ext;
  char *value;

  PREINIT:
  BASIC_CONSTRAINTS *bs;
  int ret = 0;

  CODE:

  /* retrieve the value of CA or pathlen in basicConstraints */
  bs = X509V3_EXT_d2i(ext);

  if (strcmp(value, "ca") == 0) {
    ret = bs->ca ? 1 : 0;

  } else if (strcmp(value, "pathlen") == 0) {
    ret = bs->pathlen ? 1 : 0;
  }

  BASIC_CONSTRAINTS_free(bs);

  RETVAL = ret;

  OUTPUT:
  RETVAL

SV*
ia5string(ext)
  Crypt::OpenSSL::X509::Extension ext;

  PREINIT:
  ASN1_IA5STRING *str;
  BIO *bio;

  CODE:

  /* retrieving the value of an ia5string object */
  bio = sv_bio_create();
  str = X509V3_EXT_d2i(ext);
  BIO_printf(bio,"%s", str->data);
  ASN1_IA5STRING_free(str);

  RETVAL = sv_bio_final(bio);

  OUTPUT:
  RETVAL

SV*
bit_string(ext)
  Crypt::OpenSSL::X509::Extension ext;

  PREINIT:
  int i, nid;
  ASN1_OBJECT *object;
  ASN1_BIT_STRING *bit_str;
  int string[10];
  BIO *bio;

  CODE:
  bio = sv_bio_create();

  object = X509_EXTENSION_get_object(ext);
  nid = OBJ_obj2nid(object);
  bit_str = X509V3_EXT_d2i(ext);

  if (nid == NID_key_usage) {

    for (i = 0; i < 9; i++) {
      string[i] = (int)ASN1_BIT_STRING_get_bit(bit_str, i);
      BIO_printf(bio, "%d", string[i]);
    }

  } else if (nid == NID_netscape_cert_type) {

    for (i = 0; i < 8; i++) {
      string[i] = (int)ASN1_BIT_STRING_get_bit(bit_str, i);
      BIO_printf(bio, "%d",  string[i]);
    }
  }

  RETVAL = sv_bio_final(bio);

  OUTPUT:
  RETVAL

SV*
extendedKeyUsage(ext)
  Crypt::OpenSSL::X509::Extension ext;

  PREINIT:
  BIO *bio;
  STACK_OF(ASN1_OBJECT) *extku;
  int nid;
  const char *value;

  CODE:

  bio   = sv_bio_create();
  extku = (STACK_OF(ASN1_OBJECT)*) X509V3_EXT_d2i(ext);

  while(sk_ASN1_OBJECT_num(extku) > 0) {
    nid = OBJ_obj2nid(sk_ASN1_OBJECT_pop(extku));
    value = OBJ_nid2sn(nid);
    BIO_printf(bio, "%s", value);
    BIO_printf(bio, " ");
  }

  RETVAL = sv_bio_final(bio);

  OUTPUT:
  RETVAL

int
auth_att(ext)
  Crypt::OpenSSL::X509::Extension ext;

  PREINIT:
  AUTHORITY_KEYID *akid;

  CODE:

  akid   = X509V3_EXT_d2i(ext);
  RETVAL = akid->keyid ? 1 : 0;

  OUTPUT:
  RETVAL

SV*
keyid_data(ext)
  Crypt::OpenSSL::X509::Extension ext;

  PREINIT:
  AUTHORITY_KEYID *akid;
  ASN1_OCTET_STRING *skid;
  int nid;
  ASN1_OBJECT *object;
  BIO *bio;

  CODE:

  bio    = sv_bio_create();
  object = X509_EXTENSION_get_object(ext);
  nid    = OBJ_obj2nid(object);

  if (nid == NID_authority_key_identifier) {

    akid = X509V3_EXT_d2i(ext);
    BIO_printf(bio, "%s", akid->keyid->data);

  } else if (nid == NID_subject_key_identifier) {

    skid = X509V3_EXT_d2i(ext);
    BIO_printf(bio, "%s", skid->data);
  }

  RETVAL = sv_bio_final(bio);

  OUTPUT:
  RETVAL

MODULE = Crypt::OpenSSL::X509    PACKAGE = Crypt::OpenSSL::X509::ObjectID
char*
name(obj)
  Crypt::OpenSSL::X509::ObjectID obj;

  PREINIT:
  char buf[128];

  CODE:

  if (obj == NULL) {
    croak("No ObjectID supplied\n");
  }

  (void)OBJ_obj2txt(buf, 128, obj, 0);

  RETVAL = buf;

  OUTPUT:
  RETVAL

char*
oid(obj)
  Crypt::OpenSSL::X509::ObjectID obj;

  PREINIT:
  char buf[128];

  CODE:

  if (obj == NULL) {
    croak("No ObjectID supplied\n");
  }

  (void)OBJ_obj2txt(buf, 128, obj, 1);

  RETVAL = buf;

  OUTPUT:
  RETVAL

MODULE = Crypt::OpenSSL::X509    PACKAGE = Crypt::OpenSSL::X509::Name

SV*
as_string(name)
  Crypt::OpenSSL::X509::Name name;

  PREINIT:
  BIO *bio;

  CODE:

  bio = sv_bio_create();
  /* this is prefered over X509_NAME_oneline() */
  X509_NAME_print_ex(bio, name, 0, XN_FLAG_SEP_CPLUS_SPC);

  RETVAL = sv_bio_final(bio);

  OUTPUT:
  RETVAL

AV*
entries(name)
  Crypt::OpenSSL::X509::Name name;

  PREINIT:
  int i, c;
  SV* rv;

  CODE:

  RETVAL = newAV();
  sv_2mortal((SV*)RETVAL);

  c = X509_NAME_entry_count(name);

  for (i = 0; i < c; i++) {
    rv = sv_make_ref("Crypt::OpenSSL::X509::Name_Entry", (void*)X509_NAME_get_entry(name, i));
    av_push(RETVAL, rv);
  }

  OUTPUT:
  RETVAL

int
get_index_by_type(name, type, lastpos = -1)
  Crypt::OpenSSL::X509::Name name;
  const char* type;
  int lastpos;

  ALIAS:
  get_index_by_long_type = 1
  has_entry = 2
  has_long_entry = 3
  has_oid_entry = 4
  get_index_by_oid_type = 5

  PREINIT:
  int nid, i;

  CODE:

  if (ix == 1 || ix == 3) {
    nid = OBJ_ln2nid(type);
  } else if (ix == 4 || ix == 5) {
    nid = OBJ_obj2nid(OBJ_txt2obj(type, /*oid*/ 1));
  } else {
    nid = OBJ_sn2nid(type);
  }

  if (!nid) {
    croak("Unknown type");
  }

  i = X509_NAME_get_index_by_NID(name, nid, lastpos);

  if (ix == 2 || ix == 3 || ix == 4) { /* has_entry */
    RETVAL = (i > lastpos)?1:0;
  } else { /* get_index */
    RETVAL = i;
  }

  OUTPUT:
  RETVAL

Crypt::OpenSSL::X509::Name_Entry
get_entry_by_type(name, type, lastpos = -1)
  Crypt::OpenSSL::X509::Name name;
  const char* type;
  int lastpos;

  ALIAS:
  get_entry_by_long_type = 1

  PREINIT:
  int nid, i;

  CODE:

  if (ix == 1) {
    nid = OBJ_ln2nid(type);
  } else {
    nid = OBJ_sn2nid(type);
  }

  if (!nid) {
    croak("Unknown type");
  }

  i = X509_NAME_get_index_by_NID(name, nid, lastpos);
  RETVAL = X509_NAME_get_entry(name, i);

  OUTPUT:
  RETVAL


MODULE = Crypt::OpenSSL::X509    PACKAGE = Crypt::OpenSSL::X509::Name_Entry

SV*
as_string(name_entry, ln = 0)
  Crypt::OpenSSL::X509::Name_Entry name_entry;
  int ln;

  ALIAS:
  as_long_string = 1

  PREINIT:
  BIO *bio;
  const char *n;
  int nid;

  CODE:
  bio = sv_bio_create();
  nid = OBJ_obj2nid(X509_NAME_ENTRY_get_object(name_entry));

  if (ix == 1 || ln) {
    n = OBJ_nid2ln(nid);
  } else {
    n = OBJ_nid2sn(nid);
  }

  BIO_printf(bio, "%s=", n);

  ASN1_STRING_print_ex(bio, X509_NAME_ENTRY_get_data(name_entry), ASN1_STRFLGS_UTF8_CONVERT & ~ASN1_STRFLGS_ESC_MSB);

  sv_bio_utf8_on(bio);

  RETVAL = sv_bio_final(bio);

  OUTPUT:
  RETVAL

SV*
type(name_entry, ln = 0)
  Crypt::OpenSSL::X509::Name_Entry name_entry;
  int ln;

  ALIAS:
  long_type = 1

  PREINIT:
  BIO *bio;
  const char *n;
  int nid;

  CODE:
  bio = sv_bio_create();
  nid = OBJ_obj2nid(X509_NAME_ENTRY_get_object(name_entry));

  if (ix == 1 || ln) {
    n = OBJ_nid2ln(nid);
  } else {
    n = OBJ_nid2sn(nid);
  }

  BIO_printf(bio, "%s", n);
  RETVAL = sv_bio_final(bio);

  OUTPUT:
  RETVAL

SV*
value(name_entry)
  Crypt::OpenSSL::X509::Name_Entry name_entry;

  PREINIT:
  BIO *bio;

  CODE:
  bio = sv_bio_create();
  ASN1_STRING_print(bio, X509_NAME_ENTRY_get_data(name_entry));
  RETVAL = sv_bio_final(bio);

  OUTPUT:
  RETVAL

int
is_printableString(name_entry, asn1_type =  V_ASN1_PRINTABLESTRING)
  Crypt::OpenSSL::X509::Name_Entry name_entry;
  int asn1_type;

  ALIAS:
  is_asn1_type = 1
  is_printableString = V_ASN1_PRINTABLESTRING
  is_ia5string = V_ASN1_IA5STRING
  is_utf8string = V_ASN1_UTF8STRING

  CODE:
  RETVAL = (X509_NAME_ENTRY_get_data(name_entry)->type == (ix == 1 ? asn1_type : ix));

  OUTPUT:
  RETVAL

char*
encoding(name_entry)
  Crypt::OpenSSL::X509::Name_Entry name_entry;

  CODE:
  RETVAL = NULL;

  if (X509_NAME_ENTRY_get_data(name_entry)->type == V_ASN1_PRINTABLESTRING) {
    RETVAL = "printableString";

  } else if(X509_NAME_ENTRY_get_data(name_entry)->type == V_ASN1_IA5STRING) {
    RETVAL = "ia5String";

  } else if(X509_NAME_ENTRY_get_data(name_entry)->type == V_ASN1_UTF8STRING) {
    RETVAL = "utf8String";
  }

  OUTPUT:
  RETVAL

MODULE = Crypt::OpenSSL::X509       PACKAGE = Crypt::OpenSSL::X509_CRL

Crypt::OpenSSL::X509::CRL
new_from_crl_string(class, string, format = FORMAT_PEM)
  SV  *class;
  SV  *string;
  int format;

  ALIAS:
  new_from_crl_file = 1

  PREINIT:
  BIO *bio;
  STRLEN len;
  char *crl;

  CODE:

  crl = SvPV(string, len);

  if (ix == 1) {
    bio = BIO_new_file(crl, "r");
  } else {
    bio = BIO_new_mem_buf(crl, len);
  }

  if (!bio) {
    croak("%s: Failed to create BIO", SvPV_nolen(class));
  }

  if (format == FORMAT_ASN1) {
    RETVAL = (X509_CRL*)d2i_X509_CRL_bio(bio, NULL);
  } else {
    RETVAL = (X509_CRL*)PEM_read_bio_X509_CRL(bio, NULL, NULL, NULL);
  }

  if (!RETVAL) {
    croak("%s: failed to read X509 certificate.", SvPV_nolen(class));
  }

  BIO_free(bio);

  OUTPUT:
  RETVAL

SV*
CRL_accessor(crl)
  Crypt::OpenSSL::X509::CRL crl;

  ALIAS:
  CRL_issuer = 1
  CRL_sig_alg_name = 2

  PREINIT:
  BIO *bio;
  X509_NAME *name;

  CODE:
  bio = sv_bio_create();

  if (ix == 1) {
    name = X509_CRL_get_issuer(crl);
    sv_bio_utf8_on(bio);
    X509_NAME_print_ex(bio, name, 0, (XN_FLAG_SEP_CPLUS_SPC | ASN1_STRFLGS_UTF8_CONVERT) & ~ASN1_STRFLGS_ESC_MSB);

  } else if (ix == 2) {
    const_ossl11 X509_ALGOR *palg;
    const_ossl11 ASN1_OBJECT *paobj;

    X509_CRL_get0_signature(crl, NULL, &palg);
    X509_ALGOR_get0(&paobj, NULL, NULL, palg);

    i2a_ASN1_OBJECT(bio, paobj);
  }

  RETVAL = sv_bio_final(bio);

  OUTPUT:
  RETVAL
