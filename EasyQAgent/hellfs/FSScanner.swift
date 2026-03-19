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


func countDirectory(_ path: String)->Int {
  guard let dir = opendir(path) else { return 0 } // 防止路径无效崩溃
  var count = 0
  
  // readdir 返回 nil 时循环结束
  while readdir(dir) != nil {
    count += 1
  }
  
  closedir(dir)
  // 只有成功打开且有内容时才减去 . 和 ..
  return max(0, count - 2)
}

class FSScanner {
  weak var delegate: ScannerDelegate?
  var attrList: attrlist
  let bufferSize: Int
  
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
    let c = countDirectory(path)
    if c > 500 {
      log("跳过超多文件目录 \(path) \(c)")
      return []
    }
    
    let fd = open(path, O_RDONLY | O_DIRECTORY)
    guard fd >= 0 else {
      perror("open")
      return []
    }
    defer { close(fd) }
    
    
    
    var buffer = [UInt8](repeating: 0, count: bufferSize)
    var files: [FileMetadata] = []
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
          
          if returned.commonattr & UInt32(ATTR_CMN_OBJTYPE) != 0 {
            let vt = reader.read(vtype.self)
            file.isDir =  vt == VDIR
          }
          
          if returned.commonattr & UInt32(ATTR_CMN_OBJTAG) != 0 {
            // todo 这个属性就是占位的, 暂时不用
            let _ = reader.read(vtagtype.self)
            // let vt = reader.read(vtagtype.self)
            //                        log("vtagtype ", vt)
          }
          
          if returned.commonattr & UInt32(ATTR_CMN_MODTIME) != 0 {
            
            let st = reader.read(timespec.self)
            file.mtime = Int64(st.tv_sec)
//            log("时间: \(st.tv_nsec) \(st.tv_sec)")
          }
          
          
          if returned.fileattr & UInt32(ATTR_FILE_TOTALSIZE) != 0 {
            
            file.size = reader.read(Int64.self)
          }
          if file.isDir && !IgnoreSet.shouldIgnore(name: file.name) {
            
            delegate?.scannerDidFindFolder("\(path)/\(file.name)")
          }
          files.append(file)
          
        }
        
        
        
      }
    }
    return files
  }
}


