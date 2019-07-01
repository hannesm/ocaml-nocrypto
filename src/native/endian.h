#if defined(__FreeBSD__) || defined(__DragonFly__) || defined(__NetBSD__) || defined(__OpenBSD__)

#include <sys/endian.h>

#elif defined(__APPLE__)

/* OS X endian.h doesn't provide be|le macros  */
#include <machine/endian.h>
#include <libkern/OSByteOrder.h>

#define htobe16(x) OSSwapHostToBigInt16(x)
#define htole16(x) OSSwapHostToLittleInt16(x)
#define be16toh(x) OSSwapBigToHostInt16(x)
#define le16toh(x) OSSwapLittleToHostInt16(x)
#define htobe32(x) OSSwapHostToBigInt32(x)
#define htole32(x) OSSwapHostToLittleInt32(x)
#define be32toh(x) OSSwapBigToHostInt32(x)
#define le32toh(x) OSSwapLittleToHostInt32(x)
#define htobe64(x) OSSwapHostToBigInt64(x)
#define htole64(x) OSSwapHostToLittleInt64(x)
#define be64toh(x) OSSwapBigToHostInt64(x)
#define le64toh(x) OSSwapLittleToHostInt64(x)

#else

/* Needs _DEFAULT_SOURCE with glibc */
#include <endian.h>

/* For freestanding builds */
#define	__bswap16_gen(x)	(__uint16_t)((x) << 8 | (x) >> 8)
#define	__bswap32_gen(x)		\
	(((__uint32_t)__bswap16((x) & 0xffff) << 16) | __bswap16((x) >> 16))
#define	__bswap64_gen(x)		\
	(((__uint64_t)__bswap32((x) & 0xffffffff) << 32) | __bswap32((x) >> 32))

#define	__bswap16(x)				\
	((__uint16_t)(__builtin_constant_p(x) ?	\
	    __bswap16_gen((__uint16_t)(x)) : __bswap16_var(x)))
#define	__bswap32(x)			\
	(__builtin_constant_p(x) ?	\
	    __bswap32_gen((__uint32_t)(x)) : __bswap32_var(x))
#define	__bswap64(x)			\
	(__builtin_constant_p(x) ?	\
	    __bswap64_gen((__uint64_t)(x)) : __bswap64_var(x))
#define bswap64(x) __bswap64(x)
#define htobe64(x) bswap64((x))
#define be64toh(x) bswap64((x))


#endif
