import simd

typealias V2 = SIMD2<Float>
typealias V3 = SIMD3<Float>

@inline(__always) func len(_ v: V2) -> Float { simd_length(v) }
@inline(__always) func norm(_ v: V2) -> V2 {
    let l = simd_length(v)
    return l > 1e-5 ? v / l : V2(0, 0)
}
@inline(__always) func mixf(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
@inline(__always) func mixv(_ a: V2, _ b: V2, _ t: Float) -> V2 { a + (b - a) * t }
@inline(__always) func clampf(_ x: Float, _ a: Float, _ b: Float) -> Float { min(max(x, a), b) }
@inline(__always) func smooth(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
    let t = clampf((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)
}
@inline(__always) func rot(_ v: V2, _ a: Float) -> V2 {
    let c = cos(a), s = sin(a)
    return V2(c * v.x - s * v.y, s * v.x + c * v.y)
}
@inline(__always) func clampLen(_ v: V2, _ m: Float) -> V2 {
    let l = simd_length(v)
    return l > m ? v * (m / l) : v
}
func angleLerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
    var d = b - a
    while d > .pi { d -= 2 * .pi }
    while d < -.pi { d += 2 * .pi }
    return a + d * t
}
