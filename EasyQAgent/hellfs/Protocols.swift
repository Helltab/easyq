protocol ScannerDelegate: AnyObject {
    func scannerDidFindFolder(_ path: String)
    func scannerDidBatchFiles(_ files: [FileMetadata])
    func scannerDidFinishProcessing(_ path: String, success: Bool)
}
