import Foundation
@inline(__always)
func align(_ value: Int, to alignment: Int) -> Int {
  return (value + alignment - 1) & ~(alignment - 1)
}
struct AttributeReader {

  let base: UnsafeRawPointer
  let entryOffset: Int

  private(set) var cursor: Int

  let formatter = DateFormatter()


  init(
    base: UnsafeRawPointer,
    entryOffset: Int
  ) {
    self.base = base
    self.entryOffset = entryOffset
    self.formatter.dateStyle = .medium
    self.formatter.timeStyle = .medium
    self.cursor = entryOffset + MemoryLayout<UInt32>.size

  }


  @inline(__always)
  mutating func setCursor(_ cur: Int) {
    self.cursor = cur
  }

  @inline(__always)
  mutating func read<T>(_ type: T.Type) -> T {

    let alignSize = MemoryLayout<T>.alignment
    cursor = align(cursor, to: alignSize)
    return readRaw(type)
  }

  @inline(__always)
  mutating func readRaw<T>(_ type: T.Type) -> T {

    let value = base.load(
      fromByteOffset: cursor,
      as: T.self
    )

    cursor += MemoryLayout<T>.size
    return value
  }


  func string(from ref: attrreference_t) -> String {

    let refAddr =
    base.advanced(by: cursor - MemoryLayout<attrreference_t>.size)

    return String(cString: refAddr
      .advanced(by: Int(ref.attr_dataoffset))
      .assumingMemoryBound(to: CChar.self))
  }


  func datetime(from ts: timespec) -> String {

    let date = Date(
      timeIntervalSince1970:
        Double(ts.tv_sec) +
      Double(ts.tv_nsec) / 1_000_000_000
    )


    return self.formatter.string(from: date)
  }
}


class FSScanner {
  weak var delegate: ScannerDelegate?
  var attrList: attrlist
  let bufferSize: Int
  /// 用户主目录的路径深度，用于计算相对深度控制软跳过目录的递归
  var homeDepth: Int = 0

  init() {
    self.attrList = attrlist(
      bitmapcount: UInt16(ATTR_BIT_MAP_COUNT),
      reserved: 0,
      commonattr:
        UInt32(ATTR_CMN_NAME) | //1  8B
      UInt32(ATTR_CMN_OBJTYPE) | //8 4B
      UInt32(ATTR_CMN_OBJTAG) | //16 4B
      UInt32(ATTR_CMN_MODTIME) | // 2048 注意这个属性是8B的, 必须保证前面的属性加起来偏移对齐8B
      //                UInt32(ATTR_CMN_FULLPATH) | // 134217728
      UInt32(ATTR_CMN_RETURNED_ATTRS) // 2147483648
      ,
      volattr: 0,
      dirattr: 0,
      fileattr: UInt32(ATTR_FILE_TOTALSIZE),
      forkattr: 0
    )

    self.bufferSize = 1024 * 1024 * 64
  }



  func scanDirectory(_ path: String)-> [FileMetadata]{
    let fd = open(path, O_RDONLY | O_DIRECTORY)
    guard fd >= 0 else {
      perror("open")
      return []
    }
    defer { close(fd) }



    var buffer = [UInt8](repeating: 0, count: bufferSize)
    var allFiles: [FileMetadata] = []
    let currentDepth = path.components(separatedBy: "/").count

    buffer.withUnsafeMutableBytes { rawBuf in

      guard let base = rawBuf.baseAddress else { return }

      while true {

        let count = getattrlistbulk(
          fd,
          &self.attrList,
          base,
          bufferSize,
          0
        )

        if count < 0 {
          perror("getattrlistbulk")
          return
        }

        if count == 0 { break }

        var entryOffset = 0
        var batch: [FileMetadata] = []

        for _ in 0..<count {

          let entryLength = base.load(
            fromByteOffset: entryOffset,
            as: UInt32.self
          )



          var file =  FileMetadata()

          var reader = AttributeReader(
            base: base,
            entryOffset: entryOffset
          )

          entryOffset += Int(entryLength)

          let returned = reader.read(attribute_set_t.self)

          if returned.commonattr & UInt32(ATTR_CMN_NAME) != 0 {

            let ref = reader.read(attrreference_t.self)

            let name = reader.string(from: ref)



            if name == "." || name == ".." || name.starts(with: ".") {
              continue
            }
            if name != "." && name != ".." {

              file.name = name
              file.parent = path
            }

          }

          // 读取文件类型，跳过符号链接和特殊文件（socket、pipe 等）
          var fileType: vtype = VNON
          if returned.commonattr & UInt32(ATTR_CMN_OBJTYPE) != 0 {
            fileType = reader.read(vtype.self)
            file.isDir = fileType == VDIR
          }
          if fileType == VLNK || fileType == VSOCK || fileType == VFIFO || fileType == VCHR || fileType == VBLK {
            continue
          }

          if returned.commonattr & UInt32(ATTR_CMN_OBJTAG) != 0 {
            // todo 这个属性就是占位的, 暂时不用
            let _ = reader.read(vtagtype.self)
          }

          if returned.commonattr & UInt32(ATTR_CMN_MODTIME) != 0 {

            let st = reader.read(timespec.self)
            file.mtime = Int64(st.tv_sec)
          }


          if returned.fileattr & UInt32(ATTR_FILE_TOTALSIZE) != 0 {

            file.size = reader.read(Int64.self)
          }

          // 递归控制：
          // - 硬跳过的目录完全不递归
          // - 软跳过的目录限制递归深度（最多再进 1 层）
          if file.isDir {
            if IgnoreSet.shouldHardSkip(name: file.name) {
              // 硬跳过：不递归，但本条记录仍然入库
            } else if IgnoreSet.shouldSoftSkip(name: file.name) {
              // 软跳过：只允许再递归 1 层（进入看一眼内容，不再深入）
              if currentDepth <= homeDepth + 1 {
                delegate?.scannerDidFindFolder("\(path)/\(file.name)")
              }
            } else {
              // 正常目录：无限制递归
              delegate?.scannerDidFindFolder("\(path)/\(file.name)")
            }
          }

          batch.append(file)
        }

        // 每个 getattrlistbulk 批次后立即通过回调入库，避免内存堆积
        if !batch.isEmpty {
          delegate?.scannerDidBatchFiles(batch)
          allFiles.append(contentsOf: batch)
        }
      }
    }
    return allFiles
  }
}
