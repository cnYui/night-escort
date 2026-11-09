import Foundation

/**
 中国大陆地图坐标换算（WGS-84 ↔ GCJ-02）。

 定位（CoreLocation、手表、上报给后端的点）都是 WGS-84；中国大陆的 Apple 地图底图是高德数据，
 地图上的坐标（镜头中心、标注位置）是 GCJ-02，两者在上海一带差约 480 米（往东南）。
 11-09 在模拟器上看到：同一个数字坐标，地图中心在人民公园，蓝点（真实定位）在大世界附近。
 所以：
 - 存家的位置、做到家判断，一律用 WGS-84（和定位一致）：地图选点保存时 gcjToWgs；
 - 把定位点画到地图上（守护人看位置、选点页回显已存的家），先 wgsToGcj。
 大陆以外（含港澳台按常用的粗略矩形判断）不换算。
 */
public enum ChinaCoordinate {
    private static let a = 6378245.0
    private static let ee = 0.00669342162296594323

    /// 粗略矩形：在这个范围外不做偏移
    public static func outOfChina(lat: Double, lng: Double) -> Bool {
        lng < 72.004 || lng > 137.8347 || lat < 0.8293 || lat > 55.8271
    }

    /// 定位坐标 → 地图坐标
    public static func wgsToGcj(lat: Double, lng: Double) -> (lat: Double, lng: Double) {
        if outOfChina(lat: lat, lng: lng) { return (lat, lng) }
        let d = delta(lat: lat, lng: lng)
        return (lat + d.lat, lng + d.lng)
    }

    /// 地图坐标 → 定位坐标（迭代逼近，误差远小于 1 米）
    public static func gcjToWgs(lat: Double, lng: Double) -> (lat: Double, lng: Double) {
        if outOfChina(lat: lat, lng: lng) { return (lat, lng) }
        var w = (lat: lat, lng: lng)
        for _ in 0..<10 {
            let g = wgsToGcj(lat: w.lat, lng: w.lng)
            w.lat -= g.lat - lat
            w.lng -= g.lng - lng
        }
        return w
    }

    private static func delta(lat: Double, lng: Double) -> (lat: Double, lng: Double) {
        var dLat = transformLat(lng - 105, lat - 35)
        var dLng = transformLng(lng - 105, lat - 35)
        let radLat = lat / 180 * .pi
        var magic = sin(radLat)
        magic = 1 - ee * magic * magic
        let sqrtMagic = magic.squareRoot()
        dLat = dLat * 180 / ((a * (1 - ee)) / (magic * sqrtMagic) * .pi)
        dLng = dLng * 180 / (a / sqrtMagic * cos(radLat) * .pi)
        return (dLat, dLng)
    }

    private static func transformLat(_ x: Double, _ y: Double) -> Double {
        var r = -100 + 2 * x + 3 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * abs(x).squareRoot()
        r += (20 * sin(6 * x * .pi) + 20 * sin(2 * x * .pi)) * 2 / 3
        r += (20 * sin(y * .pi) + 40 * sin(y / 3 * .pi)) * 2 / 3
        r += (160 * sin(y / 12 * .pi) + 320 * sin(y * .pi / 30)) * 2 / 3
        return r
    }

    private static func transformLng(_ x: Double, _ y: Double) -> Double {
        var r = 300 + x + 2 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * abs(x).squareRoot()
        r += (20 * sin(6 * x * .pi) + 20 * sin(2 * x * .pi)) * 2 / 3
        r += (20 * sin(x * .pi) + 40 * sin(x / 3 * .pi)) * 2 / 3
        r += (150 * sin(x / 12 * .pi) + 300 * sin(x / 30 * .pi)) * 2 / 3
        return r
    }
}
