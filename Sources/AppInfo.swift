// App 名稱：從 Info.plist 讀取（由 build.sh 依 app.env 寫入），改名不用改程式
import Foundation

enum AppInfo {
    static let name = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "SplitSwan"
}
