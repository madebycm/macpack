import Foundation
import MacPackShared

guard geteuid() == 0 else {
    FileHandle.standardError.write(
        Data("MacPackInstaller must be launched by the system service manager.\n".utf8)
    )
    exit(EX_NOPERM)
}

let listener = NSXPCListener(machServiceName: MacPackConstants.helperMachService)
let delegate = InstallerListenerDelegate()
listener.delegate = delegate
listener.resume()
dispatchMain()
