#include "MemoryMappedFile.h"
#include "BORGVRDataBase.h"

#include <cerrno>
#include <cstring>

#if defined(_WIN32)
  #define NOMINMAX
  #include <windows.h>
#else
  #include <fcntl.h>
  #include <sys/mman.h>
  #include <sys/stat.h>
  #include <unistd.h>
#endif

static std::string sysErrorString() {
#if defined(_WIN32)
  DWORD err = GetLastError();
  LPVOID msgBuf = nullptr;
  const DWORD flags = FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
                      FORMAT_MESSAGE_IGNORE_INSERTS;
  const DWORD len = FormatMessageA(flags, NULL, err,
                                  MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
                                  (LPSTR)&msgBuf, 0, NULL);
  std::string msg = (len && msgBuf) ? std::string((LPSTR)msgBuf, len) : "Unknown error";
  if (msgBuf) LocalFree(msgBuf);
  return msg;
#else
  return std::string(std::strerror(errno));
#endif
}

MemoryMappedFile::MemoryMappedFile(const std::string& filename) : filename_(filename) {
#if defined(_WIN32)
  HANDLE hFile = CreateFileA(
    filename.c_str(),
    GENERIC_READ,
    FILE_SHARE_READ,
    NULL,
    OPEN_EXISTING,
    FILE_ATTRIBUTE_NORMAL,
    NULL
  );
  if (hFile == INVALID_HANDLE_VALUE) {
    throw BorgVRException(BorgVRDataErrorCode::IoError,
                          "CreateFile failed: " + sysErrorString());
  }

  LARGE_INTEGER sizeLI{};
  if (!GetFileSizeEx(hFile, &sizeLI)) {
    CloseHandle(hFile);
    throw BorgVRException(BorgVRDataErrorCode::IoError,
                          "GetFileSizeEx failed: " + sysErrorString());
  }
  if (sizeLI.QuadPart <= 0) {
    CloseHandle(hFile);
    throw BorgVRException(BorgVRDataErrorCode::IoError,
                          "File size is zero or negative.");
  }
  size_ = static_cast<size_t>(sizeLI.QuadPart);

  HANDLE hMap = CreateFileMappingA(hFile, NULL, PAGE_READONLY, 0, 0, NULL);
  if (!hMap) {
    CloseHandle(hFile);
    throw BorgVRException(BorgVRDataErrorCode::IoError,
                          "CreateFileMapping failed: " + sysErrorString());
  }

  void* view = MapViewOfFile(hMap, FILE_MAP_READ, 0, 0, 0);
  if (!view) {
    CloseHandle(hMap);
    CloseHandle(hFile);
    throw BorgVRException(BorgVRDataErrorCode::IoError,
                          "MapViewOfFile failed: " + sysErrorString());
  }

  hFile_ = hFile;
  hMap_ = hMap;
  data_ = reinterpret_cast<const uint8_t*>(view);

#else
  fd_ = ::open(filename.c_str(), O_RDONLY);
  if (fd_ < 0) {
    throw BorgVRException(BorgVRDataErrorCode::IoError,
                          "open failed: " + sysErrorString());
  }

  struct stat st{};
  if (fstat(fd_, &st) != 0) {
    ::close(fd_);
    fd_ = -1;
    throw BorgVRException(BorgVRDataErrorCode::IoError,
                          "fstat failed: " + sysErrorString());
  }
  if (st.st_size <= 0) {
    ::close(fd_);
    fd_ = -1;
    throw BorgVRException(BorgVRDataErrorCode::IoError,
                          "File size is zero or negative.");
  }
  size_ = static_cast<size_t>(st.st_size);

  void* mapping = mmap(nullptr, size_, PROT_READ, MAP_SHARED, fd_, 0);
  if (mapping == MAP_FAILED) {
    ::close(fd_);
    fd_ = -1;
    throw BorgVRException(BorgVRDataErrorCode::IoError,
                          "mmap failed: " + sysErrorString());
  }

  data_ = reinterpret_cast<const uint8_t*>(mapping);
#endif
}

MemoryMappedFile::~MemoryMappedFile() {
#if defined(_WIN32)
  if (data_) {
    UnmapViewOfFile(data_);
    data_ = nullptr;
  }
  if (hMap_) {
    CloseHandle(reinterpret_cast<HANDLE>(hMap_));
    hMap_ = nullptr;
  }
  if (hFile_) {
    CloseHandle(reinterpret_cast<HANDLE>(hFile_));
    hFile_ = nullptr;
  }
#else
  if (data_) {
    munmap(const_cast<uint8_t*>(data_), size_);
    data_ = nullptr;
  }
  if (fd_ >= 0) {
    ::close(fd_);
    fd_ = -1;
  }
#endif
}

/*
 Copyright (c) 2026 Computer Graphics and Visualization Group, University of Duisburg-Essen

 Permission is hereby granted, free of charge, to any person obtaining a copy of this
 software and associated documentation files (the "Software"), to deal in the Software
 without restriction, including without limitation the rights to use, copy, modify,
 merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
 permit persons to whom the Software is furnished to do so, subject to the following
 conditions:

 The above copyright notice and this permission notice shall be included in all copies or
 substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
 PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
 BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
 OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
 IN THE SOFTWARE.
 */
