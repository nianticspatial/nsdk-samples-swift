import CArdk

protocol NsdkApiBase {
    func createResourceOwner(handle: ARDK_ResourceHandle) -> ResourceOwner
    func releaseResource(handle: ARDK_ResourceHandle)
}

class CArdkApiBase: NsdkApiBase {
    init() { }

    func createResourceOwner(handle: ARDK_ResourceHandle) -> ResourceOwner {
        return ResourceHandleOwner(handle: handle)
    }
    
    func releaseResource(handle: ARDK_ResourceHandle) {
        ARDK_Release_Resource(handle)
    }
}
