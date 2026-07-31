// Generated for macOS. Do not edit by hand.
// Provides LevelDB platform configuration without running CMake.
#ifndef STORAGE_LEVELDB_PORT_PORT_CONFIG_H_
#define STORAGE_LEVELDB_PORT_PORT_CONFIG_H_

// Define to 1 if you have a definition for fdatasync() in <unistd.h>.
#if !defined(HAVE_FDATASYNC)
#define HAVE_FDATASYNC 0
#endif

// Define to 1 if you have a definition for F_FULLFSYNC in <fcntl.h>.
#if !defined(HAVE_FULLFSYNC)
#define HAVE_FULLFSYNC 1
#endif

// Define to 1 if you have a definition for O_CLOEXEC in <fcntl.h>.
#if !defined(HAVE_O_CLOEXEC)
#define HAVE_O_CLOEXEC 1
#endif

// Define to 1 if you have Google CRC32C.
#if !defined(HAVE_CRC32C)
#define HAVE_CRC32C 0
#endif

// Define to 1 if you have Google Snappy.
#if !defined(HAVE_SNAPPY)
#define HAVE_SNAPPY 0
#endif

#endif  // STORAGE_LEVELDB_PORT_PORT_CONFIG_H_
