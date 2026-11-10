import CoreLocation
import EscortKit

extension CLLocationCoordinate2D {
    /// 定位点（WGS-84，手机和手表上报的都是）画到地图上用的坐标：中国大陆的 Apple 地图是 GCJ-02，要先换算，不然差约 500 米
    static func onMap(lat: Double, lng: Double) -> CLLocationCoordinate2D {
        let g = ChinaCoordinate.wgsToGcj(lat: lat, lng: lng)
        return CLLocationCoordinate2D(latitude: g.lat, longitude: g.lng)
    }

    /// 地图上取到的坐标（镜头中心等）换回定位用的 WGS-84，存家的位置、做到家判断都用这个
    var forLocation: (lat: Double, lng: Double) {
        ChinaCoordinate.gcjToWgs(lat: latitude, lng: longitude)
    }
}
