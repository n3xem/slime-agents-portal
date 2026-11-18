let shaderSource = #"""
#include <metal_stdlib>
using namespace metal;

struct U { float2 size; float scale; float time; uint groupCount; uint lumpCount; float bandY; uint islandCount; float2 cam; float zoom; float pad; };
struct Blob { float2 p; float r; float pad; float4 c; };
struct Seg { float2 a; float2 b; float ra; float rb; float ua; float ub; };
struct Group { float4 box; uint kind; uint start; uint count; uint flags; float4 color; float4 color2; float4 params; };

struct VOut { float4 pos [[position]]; float2 uv; };

vertex VOut vmain(uint vid [[vertex_id]]) {
    float2 t = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.pos = float4(t * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(t.x, 1.0 - t.y);
    return o;
}

constant float K = 2.0;
constant float T = 0.421875;
constant float2 SHADOW_OFF = float2(7.0, 16.0);

float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

float vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 w = f * f * (3.0 - 2.0 * f);
    float a = hash21(i), b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0)), d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
}

float sminf(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

struct IslandSample { float d; float ring; };

IslandSample islandField(float2 p, uint i, constant U& u, const device float4* isl,
                         const device float4* iblobs, const device float4* ripples) {
    float4 r = isl[i * 4];
    float4 m = isl[i * 4 + 2];
    float4 m2 = isl[i * 4 + 3];
    float appear = m.x;
    float seed = m.y;
    float z = u.zoom;
    float2 pw = u.cam + p / z;
    float2 c = r.xy + r.zw * 0.5;
    float2 h = r.zw * 0.5 * appear;
    float rad = min(78.0 * z, min(h.x, h.y));
    float2 q = abs(p - c) - h + rad;
    float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - rad;
    float t = u.time;
    float n1 = vnoise(pw * 0.010 + float2(t * 0.11 + seed, -t * 0.08)) - 0.5;
    float n2 = vnoise(pw * 0.024 + float2(-t * 0.19, t * 0.13 + seed * 3.1)) - 0.5;
    d += (n1 * 15.0 + n2 * 2.5 + sin(t * 1.3 + seed) * 2.0) * z;
    uint bs = uint(m.z), bc = uint(m.w);
    for (uint k = bs; k < bs + bc; k++) {
        float4 b = iblobs[k];
        if (b.z > 0.5) { d = sminf(d, length(p - b.xy) - b.z, 58.0 * z); }
    }
    float ring = 0.0;
    uint rs = uint(m2.x), rc = uint(m2.y);
    for (uint k = rs; k < rs + rc; k++) {
        float4 rp = ripples[k];
        float age = t - rp.z;
        float R = age * 250.0 * z;
        float dist = length(p - rp.xy);
        float env = exp(-age * 1.7) * rp.w;
        float w1 = exp(-pow((dist - R) / (24.0 * z), 2.0)) * env;
        float w2 = exp(-pow((dist - R * 0.62) / (16.0 * z), 2.0)) * env * 0.55;
        ring += w1 + w2;
        d -= (w1 * 14.0 + w2 * 6.0) * z * smoothstep(90.0 * z, 0.0, abs(d));
    }
    IslandSample o;
    o.d = d;
    o.ring = ring;
    return o;
}

float3 background(float2 p, constant U& u, const device float4* isl, const device float4* iblobs,
                  const device float4* ripples, bool detail) {
    float2 uvn = p / u.size;
    float3 c = mix(float3(0.085, 0.09, 0.13), float3(0.035, 0.038, 0.058), uvn.y);
    float2 dd2 = (uvn - float2(0.5, 0.58)) * float2(u.size.x / u.size.y, 1.0);
    c += float3(0.05, 0.055, 0.095) * exp(-dot(dd2, dd2) * 2.2);
    float sp = 28.0;
    float2 pw0 = u.cam + p / u.zoom;
    float2 f = fract(pw0 / sp) - 0.5;
    float dd = length(f) * sp * min(u.zoom, 1.0);
    float dotv = (1.0 - smoothstep(0.6, 1.4, dd));
    c += float3(0.10, 0.11, 0.16) * dotv * 0.55;
    float2 v = uvn - 0.5;
    c *= 1.0 - dot(v, v) * 0.85;
    for (uint i = 0; i < u.islandCount; i++) {
        float4 r = isl[i * 4];
        float pad = 140.0;
        if (p.x < r.x - pad || p.y < r.y - pad || p.x > r.x + r.z + pad || p.y > r.y + r.w + pad) continue;
        float3 ic = isl[i * 4 + 1].rgb;
        float glow = isl[i * 4 + 1].w;
        IslandSample s0 = islandField(p, i, u, isl, iblobs, ripples);
        float pop = isl[i * 4 + 3].z;
        float push = pop * 34.0 * u.zoom;
        float d = s0.d - push;
        float burst = smoothstep(0.0, 0.3, pop);
        float seed = isl[i * 4 + 2].y;
        float tear = pop > 0.0 ? smoothstep(pop * 1.3 - 0.15, pop * 1.3 + 0.05, vnoise(p * 0.045 + seed * 7.0)) : 1.0;
        float fadeRim = tear * (1.0 - pop * 0.6);
        float inside = (1.0 - smoothstep(-4.0, 3.0, d)) * (1.0 - burst);
        float swirl = vnoise(pw0 * 0.0045 + float2(u.time * 0.05 + seed, -u.time * 0.035))
                    + 0.5 * vnoise(pw0 * 0.011 + float2(-u.time * 0.07, u.time * 0.06 + seed));
        float thick = swirl * 0.9 + d * 0.006 + u.time * 0.04 + seed * 0.13;
        float3 film = 0.5 + 0.5 * cos(6.2831 * (thick + float3(0.0, 0.33, 0.67)));
        float3 tint = mix(film, ic, 0.35);
        c = mix(c, c * 0.97 + tint * 0.018, inside);
        c += tint * inside * 0.10 * exp(-max(-d, 0.0) / 26.0);
        c += tint * inside * 0.022 * smoothstep(0.55, 1.1, swirl);
        c += ic * 0.05 * (1.0 - inside) * exp(-max(d, 0.0) / 30.0) * (1.0 - burst);
        c += (tint * 0.30 + float3(0.05)) * min(s0.ring, 1.5) * inside;
        c += ic * glow * 0.08 * inside;
        if (detail) {
            float e = 2.0;
            float dx = islandField(p + float2(e, 0.0), i, u, isl, iblobs, ripples).d - push - d;
            float dy = islandField(p + float2(0.0, e), i, u, isl, iblobs, ripples).d - push - d;
            float2 nrm = normalize(float2(dx, dy) + 1e-5);
            float light = max(dot(-nrm, normalize(float2(-0.45, -0.9))), 0.0);
            float back = max(dot(-nrm, normalize(float2(0.55, 0.8))), 0.0);
            float rim = exp(-pow(d / 3.2, 2.0));
            float halo = exp(-pow(d / 9.0, 2.0));
            float spec = exp(-pow((d + 9.0) / 5.5, 2.0));
            c += tint * rim * (0.22 + 0.25 * light) * fadeRim;
            c += tint * halo * 0.06 * fadeRim;
            c += float3(1.0) * spec * pow(light, 6.0) * 0.45 * (1.0 - burst);
            c += float3(1.0) * spec * pow(back, 10.0) * 0.12 * (1.0 - burst);
            c += tint * rim * glow * 0.3 * fadeRim;
            if (pop > 0.0) {
                float2 cc = r.xy + r.zw * 0.5;
                float2 dir = normalize(p - cc + 1e-4);
                float2 q = p - dir * (push + pop * 60.0);
                float dq = islandField(q, i, u, isl, iblobs, ripples).d;
                float2 cell = floor(q / 13.0);
                float hh = hash21(cell + seed);
                float dd = length(q - (cell + 0.5) * 13.0);
                float rad = 2.8 * (1.0 - pop) + 0.4;
                float drop = step(0.78, hh) * (1.0 - smoothstep(0.0, 9.0, abs(dq))) * (1.0 - smoothstep(rad * 0.6, rad, dd));
                c += mix(tint, float3(1.0), 0.55) * drop * smoothstep(0.0, 0.15, pop) * (1.0 - pop) * 0.9;
            }
        }
    }
    return c;
}

float3 bandColor(float x, const device float4* lumps, uint n) {
    float3 acc = float3(0.0);
    float ws = 0.0;
    for (uint i = 0; i < n; i++) {
        float d = (x - lumps[i].x) / 120.0;
        float w = exp(-d * d) + 1e-4;
        acc += w * lumps[i].yzw;
        ws += w;
    }
    return acc / max(ws, 1e-4);
}

struct Eval { float sd; float2 dir; float3 col; float bevel; float3 emis; float4 params; };

fragment float4 fmain(VOut in [[stage_in]],
                      constant U& u [[buffer(0)]],
                      const device Group* groups [[buffer(1)]],
                      const device Blob* blobs [[buffer(2)]],
                      const device Seg* segs [[buffer(3)]],
                      const device float4* lumps [[buffer(4)]],
                      const device float4* isl [[buffer(5)]],
                      const device float4* iblobs [[buffer(6)]],
                      const device float4* ripples [[buffer(7)]]) {
    float2 p = in.uv * u.size;

    float sdA = -1e4;
    float2 dirA = float2(0.0);
    float3 colA = float3(0.0);
    float bevA = 1.0;
    float3 emA = float3(0.0);
    float4 parA = float4(0.0);
    float2 cenA = float2(0.0);
    float sh = 0.0;
    float3 shc = float3(0.0);

    for (uint gi = 0; gi < u.groupCount; gi++) {
        Group gr = groups[gi];
        if (p.x < gr.box.x || p.y < gr.box.y || p.x > gr.box.z || p.y > gr.box.w) continue;
        Eval e;
        e.emis = float3(0.0);
        e.params = gr.params;
        if (gr.kind == 1) {
            float bestS = -1e4; float bu = 0.0; float br = 1.0; float2 bdir = float2(0.0);
            float shBest = 0.0;
            for (uint i = gr.start; i < gr.start + gr.count; i++) {
                Seg s = segs[i];
                float2 ba = s.b - s.a;
                float bb = max(dot(ba, ba), 1e-4);
                float h = clamp(dot(p - s.a, ba) / bb, 0.0, 1.0);
                float2 cp = s.a + ba * h;
                float d = length(p - cp);
                float r = mix(s.ra, s.rb, h);
                float sd = r - d;
                if (sd > bestS) { bestS = sd; bu = mix(s.ua, s.ub, h); br = r; bdir = (cp - p) / max(d, 1e-4); }
                float2 ps = p - SHADOW_OFF * 0.6;
                float hs = clamp(dot(ps - s.a, ba) / bb, 0.0, 1.0);
                float ds = length(ps - (s.a + ba * hs));
                float w = max(0.0, 1.0 - ds / (r * 3.2));
                shBest = max(shBest, w * w);
            }
            float alpha = gr.params.y;
            sh += shBest * 0.7 * alpha;
            shc += shBest * 0.7 * alpha * gr.color.rgb;
            e.sd = bestS - (1.0 - alpha) * 12.0;
            e.dir = bdir;
            e.col = mix(gr.color.rgb, gr.color2.rgb, smoothstep(0.15, 0.85, bu));
            e.bevel = br;
            float L = gr.params.x;
            float autoSend = gr.params.z;
            float s = bu * L;
            float v = clamp(1.0 - bestS / max(br, 1e-3), 0.0, 1.0);
            float ends = smoothstep(30.0, 52.0, s) * smoothstep(30.0, 52.0, L - s);
            float t = fract(s / 64.0) * 64.0 - 32.0;
            float x = t + br * 1.1 * v;
            float band = smoothstep(-6.0, -5.0, x) * (1.0 - smoothstep(-1.5, -0.5, x));
            float band2 = smoothstep(1.0, 2.0, x) * (1.0 - smoothstep(5.5, 6.5, x));
            float m = max(band, autoSend > 0.5 ? band2 : 0.0) * (1.0 - smoothstep(0.75, 0.92, v));
            e.col = mix(e.col, mix(e.col, float3(1.0), 0.75), m * ends);
            e.params = float4(0.0);
        } else {
            float f = 0.0; float2 g = float2(0.0); float3 col = float3(0.0); float rs = 0.0;
            for (uint i = gr.start; i < gr.start + gr.count; i++) {
                Blob b = blobs[i];
                float2 d = p - b.p;
                float R = b.r * K;
                float R2 = R * R;
                float q = dot(d, d) / R2;
                if (q < 1.0) {
                    float w = 1.0 - q; float w2 = w * w; float w3 = w2 * w;
                    f += w3; g += -6.0 * w2 * d / R2; col += w3 * b.c.rgb; rs += w3 * b.r;
                }
                float2 ds = p - b.p - SHADOW_OFF;
                float Rs = R * 1.2;
                float qs = dot(ds, ds) / (Rs * Rs);
                if (qs < 1.0) { float ws = 1.0 - qs; float ws3 = ws * ws * ws; sh += ws3 * 0.8; shc += ws3 * 0.8 * b.c.rgb; }
            }
            if (gr.kind == 2) {
                float wave = 3.0 * sin(p.x * 0.017 + u.time * 0.9) + 2.0 * sin(p.x * 0.043 - u.time * 1.3);
                float yc = u.bandY - 36.0 + wave;
                float Rb = 72.0;
                float v = (p.y - yc) / Rb;
                float w = 1.0 - v * v;
                if (w > 0.0) {
                    float w2 = w * w; float w3 = w2 * w;
                    f += w3; g.y += 3.0 * w2 * (-2.0 * v / Rb);
                    col += w3 * bandColor(p.x, lumps, u.lumpCount); rs += w3 * 30.0;
                }
                float vs = (p.y - SHADOW_OFF.y - yc) / (Rb * 1.1);
                float wsb = max(0.0, 1.0 - vs * vs);
                float shb = wsb * wsb * wsb * 0.8;
                sh += shb; shc += shb * bandColor(p.x, lumps, u.lumpCount);
            }
            if (f < 1e-5) {
                e.sd = -1e4; e.dir = float2(0.0); e.col = float3(0.0); e.bevel = 1.0;
            } else {
                float gl = max(length(g), 1e-5);
                e.sd = min((f - T) / gl, 400.0);
                e.dir = g / gl;
                e.col = col / f;
                e.bevel = (rs / f) * 0.9;
            }
            float glow = gr.params.y;
            float running = gr.params.z;
            if (glow > 0.0 || running > 0.0) {
                float edge = 1.0 - smoothstep(0.0, e.bevel * 0.7, e.sd);
                float pulseG = 0.6 + 0.4 * sin(u.time * 6.0);
                float ang = atan2(p.y - gr.color.y, p.x - gr.color.x);
                float swirl = 0.5 + 0.5 * sin(ang * 3.0 - u.time * 5.0);
                e.emis = mix(e.col, float3(1.0), 0.5) * edge * (glow * pulseG * 0.9 + running * swirl * 0.55);
            }
        }
        float k = 10.0;
        float h = clamp(0.5 + 0.5 * (e.sd - sdA) / k, 0.0, 1.0);
        sdA = mix(sdA, e.sd, h) + k * h * (1.0 - h);
        dirA = mix(dirA, e.dir, h);
        colA = mix(colA, e.col, h);
        bevA = mix(bevA, e.bevel, h);
        emA = mix(emA, e.emis, h);
        parA = mix(parA, e.params, h);
        cenA = mix(cenA, gr.color.xy, h);
    }

    float3 bg = background(p, u, isl, iblobs, ripples, true);
    float shAmt = smoothstep(0.02, 0.6, sh);
    float3 shCol = sh > 1e-4 ? shc / sh : float3(0.0);
    bg = mix(bg, bg * 0.32 + shCol * 0.06, shAmt * 0.85);

    float px = 1.0 / u.scale;
    float alpha = smoothstep(-0.85 * px, 0.85 * px, sdA);
    float grain = (hash21(p * u.scale + fract(u.time) * 17.0) - 0.5) * 0.014;
    if (alpha <= 0.0) {
        return float4(bg + grain, 1.0);
    }

    float dl = length(dirA);
    float2 dir = dl > 1e-5 ? dirA / dl : float2(0.0);
    float B = max(bevA, 2.0);
    float s = clamp(sdA, 0.0, B);
    float z = sqrt(max(B * B - (B - s) * (B - s), 1e-4));
    float slope = min((B - s) / z, 7.0);
    float3 n = normalize(float3(-dir * slope, 1.0));
    float thick = z / B;

    float3 L = normalize(float3(-0.5, -0.78, 0.9));
    float3 H = normalize(L + float3(0.0, 0.0, 1.0));
    float ndl = max(dot(n, L), 0.0);
    float3 base = colA;

    float2 rp = p - n.xy * 26.0 * thick + dir * 6.0;
    float3 refr = background(rp, u, isl, iblobs, ripples, false);

    float3 body = base * (0.28 + 0.66 * thick) * (0.5 + 0.62 * ndl);
    body = mix(body, refr * base * 2.6 + base * 0.12, 0.24);

    float2 Lxy = normalize(L.xy);
    float far = max(dot(-dir, -Lxy), 0.0);
    float ssMask = smoothstep(0.05, 0.5, thick) * (1.0 - smoothstep(0.55, 0.98, thick));
    body += base * 1.15 * far * ssMask * 0.6;

    float inner = smoothstep(0.6, 1.0, thick);
    body += base * inner * 0.10;

    float fres = pow(1.0 - n.z, 3.0);
    body += mix(base, float3(1.0), 0.5) * fres * 0.5;

    float nh = max(dot(n, H), 0.0);
    body += pow(nh, 150.0) * 1.6 + pow(nh, 24.0) * 0.17;
    float3 L2 = normalize(float3(0.6, 0.65, 0.55));
    body += pow(max(dot(n, normalize(L2 + float3(0, 0, 1))), 0.0), 60.0) * 0.22 * mix(base, float3(1.0), 0.5);

    float royal = parA.w;
    if (royal > 0.001) {
        float2 lp = p - cenA;
        float3 gold = float3(1.0, 0.76, 0.28);
        float band = smoothstep(0.0, 0.06, thick) * (1.0 - smoothstep(0.3, 0.46, thick));
        float3 goldLit = gold * (0.35 + 0.95 * ndl) + float3(1.0, 0.95, 0.8) * (pow(nh, 40.0) * 1.4 + fres * 0.35);
        body = mix(body, goldLit, band * royal);
        float inlay = smoothstep(0.5, 0.55, thick) * (1.0 - smoothstep(0.55, 0.6, thick));
        body += gold * inlay * 0.35 * royal;
        float sweep = fract((lp.x + lp.y) * 0.004 - u.time * 0.22);
        float sheen = exp(-pow((sweep - 0.5) / 0.035, 2.0));
        body += mix(gold, float3(1.0), 0.6) * sheen * 0.32 * smoothstep(0.1, 0.5, thick) * royal;
        float2 cell = floor(lp / 11.0);
        float2 f = lp - (cell + 0.5) * 11.0;
        float hh = hash21(cell + 3.7);
        float tw = pow(max(0.0, sin(u.time * (1.5 + hh * 2.5) + hh * 40.0)), 12.0);
        float star = max(exp(-abs(f.x) * 1.6) * exp(-abs(f.y) * 0.45), exp(-abs(f.y) * 1.6) * exp(-abs(f.x) * 0.45));
        body += float3(1.0, 0.93, 0.75) * star * tw * step(0.72, hh) * smoothstep(0.2, 0.6, thick) * 0.9 * royal;
    }

    body += emA;
    body *= 1.0 + parA.x * 0.10;

    float3 outc = mix(bg, body, alpha);
    return float4(outc + grain, 1.0);
}
"""#
