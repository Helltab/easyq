import Foundation




func readDirNamesOnlyNameAttr(dirName: String) {
    let dirfd = open(dirName, O_RDONLY | O_DIRECTORY)
    guard dirfd >= 0 else {
        print("无法打开目录: \(String(cString: strerror(errno)))")
        return
    }
    defer { close(dirfd) }

    // 配置 attrlist：只请求名称属性
    var attrList = attrlist(
         bitmapcount: UInt16(ATTR_BIT_MAP_COUNT),
         reserved: 0,
         commonattr: UInt32(ATTR_CMN_NAME)
         //    | UInt32(ATTR_CMN_ADDEDTIME)
             | UInt32(ATTR_CMN_FULLPATH)
             | UInt32(ATTR_CMN_RETURNED_ATTRS)
             | UInt32(ATTR_CMN_ERROR),
         volattr: 0,
         dirattr: 0,
         fileattr: UInt32(ATTR_FILE_TOTALSIZE),
         forkattr: 0,
        
    )
    let bufferSize = 65536 // 增大缓冲区以适应更多条目
    var attrBuf = [UInt8](repeating: 0, count: bufferSize)
    
    
    

    // 使用 withUnsafeMutableBytes 处理读取
    attrBuf.withUnsafeMutableBytes { rawBuffer in
        let basePtr = rawBuffer.baseAddress!
        
        while true {
            let retCount = getattrlistbulk(dirfd, &attrList, basePtr, bufferSize, 0)
            
            if retCount < 0 {
                print("读取错误: \(String(cString: strerror(errno)))")
                break
            }
            if retCount == 0 { break } // 读取完毕

            func fetchStringAttr( offset: Int)->String {
                
                let ref = rawBuffer.load(fromByteOffset: offset, as: attrreference_t.self)
                let attrPtr = basePtr.advanced(by: offset + Int(ref.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
                return String(cString: attrPtr)
            }
            
            
            func matchCMNState( offset: Int, state: UInt32)->Bool {
                
                let ref = rawBuffer.load(fromByteOffset: offset + MemoryLayout<UInt32>.size, as: attribute_set_t.self)
                return ref.commonattr & UInt32(state) != 0
            }
            
            func matchFileState( offset: Int, state: UInt32)->Bool {
                
                let ref = rawBuffer.load(fromByteOffset: offset + MemoryLayout<UInt32>.size, as: attribute_set_t.self)
                return ref.fileattr & UInt32(state) != 0
            }
            
            
            
            func fetchNumericAttr<T>(offset: Int, type: T.Type) -> T {
                return rawBuffer.load(fromByteOffset: offset, as: T.self)
            }
            var entryOffset = 0
            for _ in 0..<retCount {
   
                let entryLength = rawBuffer.load(fromByteOffset: entryOffset, as: UInt32.self)
                for i in 0..<Int(entryLength) {
                    let v = rawBuffer.load(fromByteOffset: entryOffset + i, as: UInt8.self)
                    print(String(format:"%02X", v), terminator:" ")
                }
                print("")
                if matchCMNState(offset: entryOffset,
                                  state: UInt32(ATTR_CMN_ERROR)) {
                    entryOffset += Int(entryLength)
                    if entryOffset >= bufferSize { break }
                    continue
                   
                }
                if matchCMNState(offset: entryOffset,
                                  state: UInt32(ATTR_CMN_NAME)) {
                    let refOffset = entryOffset + MemoryLayout<UInt32>.size + MemoryLayout<attribute_set_t>.size
                    
                    let off = fetchNumericAttr(offset: refOffset, type: UInt32.self)
                    print(off)
                    let fileName =  fetchStringAttr(offset: refOffset)
                    
                    if fileName != "." && fileName != ".." {
                        print("找到文件: \(fileName)")
                    }
                }
                if matchFileState(offset: entryOffset,
                                  state: UInt32(ATTR_FILE_TOTALSIZE)) {
                    print("找到文件 entryOffset: \(entryOffset)")
                }
                if matchCMNState(offset: entryOffset,
                                        state: UInt32(ATTR_CMN_FULLPATH)) {
                    let refOffset = entryOffset
                    + MemoryLayout<UInt32>.size
                    + MemoryLayout<attribute_set_t>.size
                    + MemoryLayout<UInt32>.size
                    + MemoryLayout<attrreference_t>.size
                    
                   
                    let fullPath = fetchStringAttr(offset: refOffset)
                          
                    print("路径: \(fullPath)")
                    
                }
                
                
            
                entryOffset += Int(entryLength)
                if entryOffset >= bufferSize { break }
            }
        }
    }
}


