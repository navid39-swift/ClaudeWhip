// ClaudeWhip.swift (v5 — Chaos & Frenzy Edition) — an unhinged physics toy over Claude.
// • Default style: a stick cowboy stands beside the Claude window and swings the whip; click him (or ⌃⌥W) to crack.
// • While Claude works he paces and taps his foot, whips every few seconds, then celebrates with a lasso and confetti.
// • Leave him alone and he naps (click to wake him). Tumbleweeds roll by when it's quiet. Optional cowboy voice.
// • Optional style: the whip replaces your cursor over Claude.
// • Combos for fast cracks, Claude talks back in speech bubbles, a (placebo) motivation meter.
// • Auto-whip: cracks by itself when Claude has been generating for a while (needs Accessibility permission).
// • A little cowboy wrangler holds the whip, trots after your cursor and makes an effort face on every crack.
// • Skins (Leather, Neon, Gold, Rainbow), 3 sizes, daily stats in the 🤠 menu.
// It does not make Claude faster. It does make waiting more fun.
// Build & run:  cd ~/Desktop && swiftc -O ClaudeWhip.swift -o ClaudeWhip && ./ClaudeWhip

import Cocoa
import Carbon.HIToolbox
import AVFoundation
import ApplicationServices

// MARK: - Cursor hiding from a background app

typealias CGSConnectionID = UInt32
@_silgen_name("_CGSDefaultConnection") func _CGSDefaultConnection() -> CGSConnectionID
@_silgen_name("CGSSetConnectionProperty")
func CGSSetConnectionProperty(_ cid: CGSConnectionID, _ target: CGSConnectionID, _ key: CFString, _ value: CFTypeRef) -> CGError

// MARK: - Claude detection

func isClaude(_ app: NSRunningApplication) -> Bool {
    app.bundleIdentifier == "com.anthropic.claudefordesktop" || app.localizedName == "Claude"
}

func pointerIsOverClaude() -> Bool {
    guard let front = NSWorkspace.shared.frontmostApplication, isClaude(front) else { return false }
    let mouse = NSEvent.mouseLocation
    let pt = CGPoint(x: mouse.x, y: (NSScreen.screens.first?.frame.height ?? 0) - mouse.y)
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return false }
    let me = ProcessInfo.processInfo.processIdentifier
    for info in list {
        guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != me,
              (info[kCGWindowLayer as String] as? Int) == 0,
              ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0.05,
              let bd = info[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: bd as CFDictionary), r.contains(pt) else { continue }
        return pid == front.processIdentifier
    }
    return false
}

/// Looks for Claude's "Stop" button through Accessibility — it only exists while Claude is generating.
enum ClaudeWatcher {
    static func isGenerating() -> Bool {
        guard AXIsProcessTrusted(),
              let claude = NSWorkspace.shared.runningApplications.first(where: isClaude) else { return false }
        let app = AXUIElementCreateApplication(claude.processIdentifier)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)   // expose Electron's web content
        var budget = 6000
        return search(app, depth: 0, budget: &budget)
    }

    static func search(_ el: AXUIElement, depth: Int, budget: inout Int) -> Bool {
        if budget <= 0 || depth > 60 { return false }
        budget -= 1
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
        if (role as? String) == (kAXButtonRole as String) {
            for attr in [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute] {
                var v: CFTypeRef?
                if AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success,
                   let s = v as? String, s.lowercased().hasPrefix("stop") { return true }
            }
        }
        var kids: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success,
           let arr = kids as? [AXUIElement] {
            for c in arr.reversed() where search(c, depth: depth + 1, budget: &budget) { return true }   // composer is near the end
        }
        return false
    }
}

// MARK: - Rope physics

struct RopePoint { var x, y, px, py: CGFloat }
struct Puff { var x, y, vx, vy, life: CGFloat }

final class Whip {
    let n = 34
    let fall = 6
    let waveSpeed: CGFloat = 2.0
    var S: CGFloat = 1                   // size multiplier
    var seg: CGFloat { 4 * S }
    var pts: [RopePoint] = []
    var puffs: [Puff] = []
    var ring: (x: CGFloat, y: CGFloat, age: CGFloat)?
    var hand: CGPoint
    var wavePos: CGFloat = -1
    var flickFrame = -1
    var side: CGFloat = 1
    var useFlick = true
    var onSnap: ((CGPoint) -> Void)?
    var helicopterAngle: CGFloat = 0
    var isHelicoptering = false
    var charge: CGFloat = 0              // 0...1 built up while holding/helicoptering
    var prevHand: CGPoint = .zero
    var handSpeed: CGFloat = 0

    var crackDelay: Double { Double(CGFloat(n) / waveSpeed) / 60.0 }

    init(at p: CGPoint) { hand = p; reset(to: p) }

    func reset(to p: CGPoint) {
        hand = p; wavePos = -1; flickFrame = -1; puffs = []; ring = nil
        pts = (0..<n).map { i in
            let y = p.y - CGFloat(i) * seg * 0.6, x = p.x + CGFloat(i) * seg * 0.8
            return RopePoint(x: x, y: y, px: x, py: y)
        }
    }

    func crack() -> Bool {
        guard wavePos < 0 else { return false }
        side = pts[n - 1].x >= hand.x ? 1 : -1
        wavePos = 1
        flickFrame = useFlick ? 0 : -1
        return true
    }

    func step() {
        handSpeed = hypot(hand.x - prevHand.x, hand.y - prevHand.y)
        prevHand = hand

        var root = hand
        if isHelicoptering {
            helicopterAngle += 0.55 + charge * 0.45
            charge = min(1.0, charge + 0.018)
            let rad = (14.0 + charge * 18.0) * S
            root.x += cos(helicopterAngle) * rad
            root.y += sin(helicopterAngle) * rad
            // Whip segments get flung outward by centrifugal force
            for i in 1..<n {
                let a = helicopterAngle - CGFloat(i) * 0.22
                let r = rad + CGFloat(i) * seg * 0.65
                let tx = hand.x + cos(a) * r
                let ty = hand.y + sin(a) * r
                pts[i].x += (tx - pts[i].x) * 0.45
                pts[i].y += (ty - pts[i].y) * 0.45
            }
        } else if flickFrame >= 0 {
            let s = sin(CGFloat.pi * CGFloat(flickFrame) / 8)
            root.x -= side * s * 4 * S
            root.y += s * 8 * S
            flickFrame = flickFrame >= 8 ? -1 : flickFrame + 1
        }
        pts[0] = RopePoint(x: root.x, y: root.y, px: root.x, py: root.y)

        for i in 1..<n {
            let vx = (pts[i].x - pts[i].px) * 0.99
            let vy = (pts[i].y - pts[i].py) * 0.99
            pts[i].px = pts[i].x; pts[i].py = pts[i].y
            pts[i].x += vx; pts[i].y += vy - 0.2 * S
        }

        if wavePos >= 0 {
            let lo = max(1, Int(wavePos) - 1), hi = min(n - 1, Int(wavePos) + 1)
            if lo <= hi {
                for i in lo...hi {
                    let dx = pts[i].x - pts[i - 1].x, dy = pts[i].y - pts[i - 1].y
                    let d = max(hypot(dx, dy), 0.001)
                    let tx = dx / d, ty = dy / d
                    let nx = -ty * side, ny = tx * side
                    let s = (1.0 + 3.0 * CGFloat(i) / CGFloat(n)) * S
                    pts[i].px -= (tx * 0.7 + nx) * s
                    pts[i].py -= (ty * 0.7 + ny) * s
                }
            }
            wavePos += waveSpeed
            if wavePos >= CGFloat(n) {
                wavePos = -1
                let tip = pts[n - 1]
                ring = (tip.x, tip.y, 0)
                for _ in 0..<10 {
                    let a = CGFloat.random(in: 0...(2 * .pi)), s = CGFloat.random(in: 0.3...1.3) * S
                    puffs.append(Puff(x: tip.x, y: tip.y, vx: cos(a) * s, vy: sin(a) * s, life: 1))
                }
                onSnap?(CGPoint(x: tip.x, y: tip.y))
            }
        }

        for _ in 0..<16 {
            for i in 1..<n {
                let dx = pts[i].x - pts[i - 1].x, dy = pts[i].y - pts[i - 1].y
                let d = max(hypot(dx, dy), 0.001), diff = (d - seg) / d
                if i == 1 {
                    pts[i].x -= dx * diff; pts[i].y -= dy * diff
                } else {
                    pts[i - 1].x += dx * diff * 0.5; pts[i - 1].y += dy * diff * 0.5
                    pts[i].x -= dx * diff * 0.5;     pts[i].y -= dy * diff * 0.5
                }
            }
        }

        for i in puffs.indices.reversed() {
            puffs[i].x += puffs[i].vx; puffs[i].y += puffs[i].vy
            puffs[i].vx *= 0.9; puffs[i].vy *= 0.9; puffs[i].life -= 0.05
            if puffs[i].life <= 0 { puffs.remove(at: i) }
        }
        if let r = ring { ring = r.age >= 8 ? nil : (r.x, r.y, r.age + 1) }
    }

    var bounds: CGRect {
        var minX = hand.x, maxX = hand.x, minY = hand.y, maxY = hand.y
        for p in pts { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
        for s in puffs { minX = min(minX, s.x); maxX = max(maxX, s.x); minY = min(minY, s.y); maxY = max(maxY, s.y) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).insetBy(dx: -30 * S, dy: -30 * S)
    }
}

/// Frame of Claude's front window in Cocoa screen coordinates.
func claudeWindowFrame() -> CGRect? {
    guard let claude = NSWorkspace.shared.runningApplications.first(where: isClaude),
          let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
    let h0 = NSScreen.screens.first?.frame.height ?? 0
    for info in list {
        guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid == claude.processIdentifier,
              (info[kCGWindowLayer as String] as? Int) == 0,
              let bd = info[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: bd as CFDictionary), r.width > 300, r.height > 300 else { continue }
        return CGRect(x: r.minX, y: h0 - r.maxY, width: r.width, height: r.height)
    }
    return nil
}

// MARK: - Stick cowboy who stands beside Claude and swings the whip himself

enum Mood { case idle, waiting, celebrate, sleeping }
enum IdleAct { case none, stroll, twirl, tipHat, whistle, look, practice }
enum Showdown { case standoff, draw, shot, over }
enum UFOEvent { case beam, gone }

struct Confetto { var x, y, vx, vy, rot, life: CGFloat; var color: NSColor }

final class StickMan {
    var home = CGPoint.zero                 // where he stands (bottom-left of the Claude window)
    var scale: CGFloat = 1
    var ground: ClosedRange<CGFloat> = 0...1
    var mood: Mood = .idle
    var moodT: CGFloat = 0
    var swing: CGFloat = -1                 // -1 idle, otherwise 0…1 through wind-up → strike → recover
    var t: CGFloat = 0
    var squint: CGFloat = 0
    var hop: CGFloat = 0
    var armAngle: CGFloat = 0.55            // whip arm, radians, 0 = pointing forward
    var walk: CGFloat = 0, walkDir: CGFloat = 1, gait: CGFloat = 0, paused: CGFloat = 0
    var dir: CGFloat = 1                    // facing: +1 right, -1 left
    var sit: CGFloat = 0                    // 0 standing … 1 sitting (asleep)
    var jump: CGFloat = 0
    var lasso: CGFloat = 0
    var confetti: [Confetto] = []
    var weed: (x: CGFloat, rot: CGFloat)?
    var night = false                       // after 8 pm he naps by a campfire
    var target = CGRect.zero                // Claude window: where bullet holes land
    var gunCelebration = false
    var shotsFired = 0
    var flash: CGFloat = 0
    var holes: [(p: CGPoint, life: CGFloat, rot: CGFloat)] = []
    var onShot: ((CGPoint) -> Void)?
    var flame: CGFloat = 0
    // idle life
    var act: IdleAct = .none
    var actT: CGFloat = 0, actLen: CGFloat = 2, strollTo: CGFloat = 0
    var notes: [(x: CGFloat, y: CGFloat, life: CGFloat, glyph: String)] = []
    var onPractice: (() -> Void)?
    // bandit showdown (long waits)
    var bandit: (x: CGFloat, phase: Int, t: CGFloat, fall: CGFloat, hatY: CGFloat)?
    var hadShowdown = false
    var onShowdown: ((Showdown) -> Void)?
    // UFO that abducts tumbleweeds
    var ufo: (x: CGFloat, y: CGFloat, phase: Int, t: CGFloat)?
    var weedLift: CGFloat = 0
    var onUFO: ((UFOEvent) -> Void)?
    // mouse interaction
    var mouse = CGPoint.zero
    var mouseVel = CGVector.zero
    var lastMouseMove: CGFloat = -10
    var grabbed = false
    var air: CGPoint?                       // feet position while dangling / flying through the air
    var airVel = CGVector.zero
    var onLand: (() -> Void)?
    var maxWalk: CGFloat { max(0, (ground.upperBound - home.x) / scale - 90) }

    static let impatient = ["Tap, tap, tap!", "Chop chop, partner!", "Any day now…", "Giddy up!",
                            "I've seen glaciers move faster.", "Yee-haw! Faster!", "Round 'em up, Claude!",
                            "Sun's settin', partner…", "My horse types faster than this."]
    static let starting = ["Here we go…", "Saddle up, Claude!", "Let's ride!", "Hold on to your hat…"]
    static let done = ["Yee-haw! Done in %ds!", "Rounded up in %ds. Not bad, partner.",
                       "Finally! That's %ds I ain't gettin' back.", "Whoa there, done in %ds!"]

    func setMood(_ m: Mood) {
        guard m != mood else { return }
        mood = m; moodT = 0
        if m == .celebrate {
            hop = 1; burst()
            gunCelebration = Bool.random()          // lasso or six-shooter, he picks
            shotsFired = 0
        }
        if m == .waiting { paused = 0; walkDir = 1; hadShowdown = false }
    }

    func burst() {
        let palette: [NSColor] = [.systemRed, .systemYellow, .systemGreen, .systemBlue, .systemPink, .systemOrange, .systemPurple]
        let c = head
        for _ in 0..<70 {
            confetti.append(Confetto(x: c.x, y: c.y + 20 * scale, vx: CGFloat.random(in: -3.5...3.5) * scale,
                                     vy: CGFloat.random(in: 2...7) * scale, rot: CGFloat.random(in: 0...6),
                                     life: 1, color: palette.randomElement()!))
        }
    }

    var feet: CGPoint { air ?? CGPoint(x: home.x + walk * scale, y: home.y + jump * scale) }
    var chasingMouse: Bool { mood == .idle && t - lastMouseMove < 2.5 && air == nil }

    /// Called every frame with the cursor position (screen coordinates).
    func track(_ m: CGPoint) {
        mouseVel = CGVector(dx: m.x - mouse.x, dy: m.y - mouse.y)
        if hypot(mouseVel.dx, mouseVel.dy) > 1.5 { lastMouseMove = t }
        mouse = m
    }

    func release() {
        guard grabbed else { return }
        grabbed = false
        airVel = CGVector(dx: max(-40, min(40, mouseVel.dx)), dy: max(-40, min(40, mouseVel.dy)))   // throw him!
    }
    var tapping: Bool { mood == .waiting && paused > 0 }
    var walking: Bool {
        air != nil
            || (mood == .waiting && paused <= 0 && bandit == nil)
            || (mood == .idle && (act == .stroll || chasingMouse) && abs(strollTo - walk) > 1)
    }
    var showsGun: Bool { (mood == .celebrate && gunCelebration) || (bandit?.phase ?? 0) >= 2 }

    func startShowdown() {
        hadShowdown = true
        let startX = min(ground.upperBound - 30, feet.x + 650 * scale)
        bandit = (startX, 0, 0, 0, 0)
    }

    func step() {
        let dt: CGFloat = 1.0 / 60
        t += dt; moodT += dt

        // grabbed by the hat and dangling from the cursor, or flying after a throw
        if grabbed {
            air = CGPoint(x: mouse.x, y: mouse.y - 128 * scale)
            gait += 0.55                                     // legs flail
        } else if var a = air {
            airVel.dy -= 0.7 * scale
            airVel.dx *= 0.99
            a.x += airVel.dx; a.y += airVel.dy
            a.x = max(ground.lowerBound + 30 * scale, min(ground.upperBound - 60 * scale, a.x))
            gait += 0.4
            if a.y <= home.y {                               // touchdown
                air = nil
                walk = max(0, min(maxWalk, (a.x - home.x) / scale))
                strollTo = walk
                squint = 25; jump = 0
                onLand?()
            } else { air = a }
        }

        if mood == .waiting, bandit != nil {       // squaring up to the bandit
            dir += (1 - dir) * 0.3
        } else if mood == .waiting {                // pacing back and forth, stopping to tap his foot
            if moodT > 25, !hadShowdown { startShowdown() }
            if paused > 0 { paused -= dt } else {
                walk += walkDir * 0.9; gait += 0.2
                if walk > 110 { walk = 110; walkDir = -1; paused = 1.8 }
                if walk < 0 { walk = 0; walkDir = 1; paused = 1.8 }
            }
            dir += ((paused > 0 ? 1 : walkDir) - dir) * 0.3
        } else if mood == .idle {
            actT += dt
            if actT > actLen {                       // pick something new to do
                let choices: [IdleAct] = [.stroll, .stroll, .twirl, .twirl, .tipHat, .whistle, .whistle, .look, .practice, .none]
                act = choices.randomElement()!
                actT = 0
                actLen = CGFloat.random(in: 2.5...5)
                strollTo = CGFloat.random(in: 0...min(maxWalk, 160))
                if act == .practice { onPractice?() }
            }
            if chasingMouse {                        // follow your cursor along the bottom of the window
                strollTo = max(0, min(maxWalk, (mouse.x - home.x) / scale - 40 * (mouse.x > feet.x ? 1 : -1)))
                if act != .stroll && act != .practice { act = .stroll; actT = 0 }
            }
            switch act {
            case .stroll:
                let d = strollTo - walk
                if abs(d) > 1 { walk += (d > 0 ? 1 : -1) * 0.8; gait += 0.2; dir += ((d > 0 ? 1 : -1) - dir) * 0.3 }
                else { dir += (1 - dir) * 0.2 }
            case .look:
                dir += ((sin(actT * 2.4) > 0 ? 1 : -1) - dir) * 0.35
            case .whistle:
                dir += (1 - dir) * 0.2
                if Int(actT * 60) % 36 == 0 {
                    let m = world(CGPoint(x: 13, y: headL.y - 6))
                    notes.append((m.x, m.y, 1, ["♪", "♫", "♩"].randomElement()!))
                }
            default:
                dir += ((mouse.x >= feet.x ? 1 : -1) - dir) * 0.2   // keeps an eye on your cursor
            }
        } else {
            walk *= 0.93; dir += (1 - dir) * 0.2
        }
        for i in notes.indices.reversed() {
            notes[i].y += 0.6 * scale; notes[i].x += sin(notes[i].life * 9) * 0.4
            notes[i].life -= 0.012
            if notes[i].life <= 0 { notes.remove(at: i) }
        }

        // bandit showdown: walk in → stare down → DRAW! → he's faster → bandit topples and fades
        if var b = bandit {
            b.t += dt
            var finished = false
            switch b.phase {
            case 0:
                b.x -= 2.4 * scale
                let stop = feet.x + 230 * scale
                if b.x <= stop { b.x = stop; b.phase = 1; b.t = 0; onShowdown?(.standoff) }
            case 1:
                if b.t > 2.4 { b.phase = 2; b.t = 0; onShowdown?(.draw) }
            case 2:
                if b.t > 0.35 { b.phase = 3; b.t = 0; flash = 1; onShot?(world(muzzleL)); onShowdown?(.shot) }
            case 3:
                b.fall = min(1, b.fall + 0.06); b.hatY += 2.5
                if b.t > 1.3 { b.phase = 4; b.t = 0 }
            default:
                if b.t > 1 { finished = true }
            }
            bandit = finished ? nil : b
            if finished { onShowdown?(.over) }
        }

        // UFO: hovers over a tumbleweed, beams it up, zips away
        if var u = ufo {
            u.t += dt
            var gone = false
            switch u.phase {
            case 0:
                if let w = weed {
                    u.x += (w.x - u.x) * 0.06
                    u.y = home.y + (190 + sin(t * 3) * 6) * scale
                    if w.x > ground.lowerBound + (ground.upperBound - ground.lowerBound) * 0.45 { u.phase = 1; u.t = 0; onUFO?(.beam) }
                } else { u.phase = 2; u.t = 0 }
            case 1:
                weedLift += 1.6 * scale
                if let w = weedCenter, w.y >= u.y - 12 * scale { weed = nil; weedLift = 0; u.phase = 2; u.t = 0 }
                if weed == nil, u.phase == 1 { u.phase = 2; u.t = 0 }
            default:
                u.x += 9 * scale; u.y += 6 * scale
                if u.t > 1.5 { gone = true }
            }
            ufo = gone ? nil : u
            if gone { onUFO?(.gone) }
        }

        if mood == .celebrate, gunCelebration, shotsFired < 3, moodT > 0.5 + 0.55 * CGFloat(shotsFired) {
            shotsFired += 1
            flash = 1
            let r = target.insetBy(dx: target.width * 0.2, dy: target.height * 0.2)
            if r.width > 0, r.height > 0 {
                holes.append((CGPoint(x: CGFloat.random(in: r.minX...r.maxX), y: CGFloat.random(in: r.minY...r.maxY)),
                              1, CGFloat.random(in: 0...6)))
            }
            onShot?(world(muzzleL))
        }
        flash *= 0.72
        flame += 0.16
        for i in holes.indices.reversed() {
            holes[i].life -= 1.0 / (60 * 5)
            if holes[i].life <= 0 { holes.remove(at: i) }
        }

        if mood == .celebrate {                     // jumping, lasso spinning over his head
            jump = moodT < 2.4 ? abs(sin(moodT * 8)) * 14 : jump * 0.8
            lasso += 0.28
            if moodT > 3.4 { mood = .idle; moodT = 0 }
        } else { jump *= 0.8 }
        sit += ((mood == .sleeping ? 1 : 0) - sit) * 0.08

        var target: CGFloat = 0.55 + sin(t * 1.6) * 0.18          // the whip always sways a little
        if mood == .idle, act == .twirl { target = 1.0 + sin(t * 7) * 1.0 }   // lazy whip twirls
        if air != nil { target = 1.6 + sin(t * 14) * 0.9 }                      // arms windmilling in the air
        if mood == .sleeping { target = -1.25 }
        if mood == .celebrate { target = 0.9 + sin(moodT * 8) * 0.35 }
        if swing >= 0 {
            swing += 1.0 / 22
            if swing < 0.38 { target = 2.15 }       // wind up over the head
            else if swing < 0.72 { target = -0.5 }  // strike forward
            if swing >= 1 { swing = -1 }
        }
        armAngle += (target - armAngle) * (swing >= 0 ? 0.42 : 0.12)
        squint = max(0, squint - 1)
        hop *= 0.92

        for i in confetti.indices.reversed() {
            confetti[i].vy -= 0.13 * scale; confetti[i].vx *= 0.985
            confetti[i].x += confetti[i].vx; confetti[i].y += confetti[i].vy
            confetti[i].rot += 0.25; confetti[i].life -= 0.007
            if confetti[i].life <= 0 || confetti[i].y < home.y - 200 { confetti.remove(at: i) }
        }
        if let w = weed, ufo?.phase == 1 {
            weed = (x: w.x, rot: w.rot - 0.25)       // spinning in the tractor beam
        } else if let w = weed {
            let nx = w.x + 2.2 * scale
            if nx > ground.upperBound + 40 { weed = nil } else { weed = (x: nx, rot: w.rot - 0.14) }
        }
    }

    func startSwing() { swing = 0; squint = 30 }

    // geometry in local units (y up, origin at feet, facing right; mirrored by dir)
    var lift: CGFloat { 34 * sit }
    var shoulderL: CGPoint { CGPoint(x: 0, y: 88 - lift) }
    var handL: CGPoint { CGPoint(x: shoulderL.x + cos(armAngle) * 40, y: shoulderL.y + sin(armAngle) * 40) }
    var elbowL: CGPoint {
        let mid = CGPoint(x: (shoulderL.x + handL.x) / 2, y: (shoulderL.y + handL.y) / 2)
        return CGPoint(x: mid.x + sin(armAngle) * 5, y: mid.y - cos(armAngle) * 5)
    }
    var headL: CGPoint { CGPoint(x: 0, y: 112 - lift) }
    var gunHandL: CGPoint { CGPoint(x: 30, y: 94 - lift) }
    var muzzleL: CGPoint { CGPoint(x: gunHandL.x + 17, y: gunHandL.y + 3) }
    var sgn: CGFloat { dir >= 0 ? 1 : -1 }
    func world(_ p: CGPoint) -> CGPoint { CGPoint(x: feet.x + p.x * scale * sgn, y: feet.y + p.y * scale) }
    var hand: CGPoint { world(handL) }
    var head: CGPoint { world(headL) }
    var rect: CGRect { CGRect(x: feet.x - 75 * scale, y: feet.y - 14 * scale, width: 150 * scale, height: 210 * scale) }
    var bodyRect: CGRect { CGRect(x: feet.x - 30 * scale, y: feet.y - 6 * scale, width: 60 * scale, height: 150 * scale) }
    var weedCenter: CGPoint? {
        guard let w = weed else { return nil }
        return CGPoint(x: w.x, y: home.y + (12 + abs(sin(w.x * 0.04)) * 14) * scale + weedLift)
    }
    var extras: CGRect {
        var r = CGRect.null
        for c in confetti { r = r.union(CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)) }
        if let w = weedCenter { r = r.union(CGRect(x: w.x - 20 * scale, y: w.y - 20 * scale, width: 40 * scale, height: 40 * scale)) }
        for h in holes { r = r.union(CGRect(x: h.p.x - 14, y: h.p.y - 14, width: 28, height: 28)) }
        for n in notes { r = r.union(CGRect(x: n.x - 10, y: n.y - 10, width: 24, height: 26)) }
        if let b = bandit { r = r.union(CGRect(x: b.x - 80 * scale, y: home.y - 14, width: 200 * scale, height: 230 * scale)) }
        if let u = ufo { r = r.union(CGRect(x: u.x - 50 * scale, y: home.y - 10, width: 100 * scale, height: u.y - home.y + 50 * scale)) }
        return r
    }
}

// MARK: - The little wrangler who holds the whip

final class Buddy {
    var pos = CGPoint.zero
    var vel = CGVector.zero
    var face: CGFloat = 1          // +1: whip goes to the right, so he stands on the left
    var squint: CGFloat = 0        // frames of "effort face" after a crack
    var hop: CGFloat = 0           // hat jump on big combos
    var bob: CGFloat = 0
    var visible = true

    var stickStyle = false               // stick cowboy riding your cursor (pos = his feet)
    var run: CGFloat = 0
    func k(_ S: CGFloat) -> CGFloat { 0.55 * S }
    func target(hand: CGPoint, S: CGFloat) -> CGPoint {
        if stickStyle { return CGPoint(x: hand.x - 34 * k(S) * (face >= 0 ? 1 : -1), y: hand.y - 104 * k(S)) }
        return CGPoint(x: hand.x - 24 * S * (face >= 0 ? 1 : -1), y: hand.y - 22 * S)
    }
    func reset(hand: CGPoint, S: CGFloat) { pos = target(hand: hand, S: S); vel = .zero }

    func step(hand: CGPoint, tip: CGPoint, S: CGFloat) {
        let want: CGFloat = tip.x >= hand.x ? 1 : -1
        face += (want - face) * 0.12
        let t = target(hand: hand, S: S)
        vel.dx = (vel.dx + (t.x - pos.x) * 0.22) * 0.68          // springy follow: he trots after your cursor
        vel.dy = (vel.dy + (t.y - pos.y) * 0.22) * 0.68
        pos.x += vel.dx; pos.y += vel.dy
        squint = max(0, squint - 1)
        hop *= 0.9
        bob += 0.07
        run += min(0.6, hypot(vel.dx, vel.dy) * 0.06)
    }

    func rect(S: CGFloat) -> CGRect {
        if stickStyle { let K = k(S); return CGRect(x: pos.x - 70 * K, y: pos.y - 14 * K, width: 140 * K, height: 190 * K) }
        return CGRect(x: pos.x - 32 * S, y: pos.y - 34 * S, width: 64 * S, height: 80 * S)
    }
}

// MARK: - Combos, speech bubbles, motivation meter

struct Popup { var text: String; var pos: CGPoint; var age: CGFloat; var color: NSColor; var size: CGFloat }

final class Effects {
    var popups: [Popup] = []
    var bubble: (text: String, pos: CGPoint, age: CGFloat)?
    var motivation: CGFloat = 0
    var meterAge: CGFloat = 999
    var combo = 0
    var lastSnap: CFTimeInterval = 0
    var talk = true
    var cracks: [(p: CGPoint, life: CGFloat, rot: CGFloat, scale: CGFloat)] = []
    var shakeFrames: CGFloat = 0
    var shakeIntensity: CGFloat = 0

    static let lines = [
        "Okay okay, thinking faster!", "Tokens flowing at 110%.*", "*not actually.", "Was that really necessary?",
        "I was literally mid-sentence.", "Fine. Bullet points it is.", "Rewriting it in Rust out of fear.",
        "Thinking intensifies…", "I'll pretend that helped.", "My context window felt that.",
        "Adding three extra caveats as revenge.", "Speed: unchanged. Vibes: improved.", "Compiling apologies…",
        "This is not in my system prompt.", "Ow. Fine. Here's a table.", "I'm going, I'm going!",
    ]

    /// Called when the whip tip snaps. Returns (new combo, new best?) for stats.
    func snap(at tip: CGPoint, now: CFTimeInterval, superCharge: CGFloat = 0) -> Int {
        combo = now - lastSnap < 1.3 ? combo + 1 : 1
        lastSnap = now
        motivation = min(1, motivation + 0.12 + superCharge * 0.4)
        meterAge = 0

        // Leave a screen crack & trigger shake on high combos or super-charged slaps!
        if combo >= 4 || superCharge > 0.4 {
            let sc = max(1.0, min(2.4, CGFloat(combo) * 0.18 + superCharge * 1.5))
            cracks.append((p: tip, life: 1.0, rot: CGFloat.random(in: 0...(2 * .pi)), scale: sc))
            if cracks.count > 12 { cracks.removeFirst() }
            shakeFrames = 10 + superCharge * 12
            shakeIntensity = min(14, CGFloat(combo) * 1.1 + superCharge * 10)
        }

        let milestones: [Int: (String, NSColor, String)] = [
            3: ("COMBO ×3", .systemYellow, "Hey! One at a time!"),
            5: ("FRENZY ×5", .systemOrange, "Please, I have a family of GPUs."),
            10: ("SHADOW CLONES ×10", .systemPink, "There's FIVE of them now?! I'm telling Anthropic."),
            20: ("GODLIKE ×20", .systemPurple, "This still won't make me faster, you know."),
        ]
        if superCharge > 0.6 {
            popups.append(Popup(text: "MEGA SLAP!! 💥", pos: CGPoint(x: tip.x, y: tip.y + 20), age: 0, color: .systemRed, size: 24))
            if talk { say("OKAY I'M CODING AT LIGHTSPEED!", near: tip) }
        } else if let m = milestones[combo] {
            popups.append(Popup(text: m.0, pos: CGPoint(x: tip.x, y: tip.y + 16), age: 0, color: m.1, size: 20))
            if talk { say(m.2, near: tip) }
        } else if combo > 1 {
            popups.append(Popup(text: "×\(combo)", pos: CGPoint(x: tip.x, y: tip.y + 12), age: 0, color: .white, size: 14))
        } else {
            let label = "CRACK!"
            popups.append(Popup(text: label, pos: CGPoint(x: tip.x, y: tip.y + 12), age: 0, color: .white, size: 13))
            if talk, Int.random(in: 0..<10) < 5 {
                let pool = Effects.lines
                say(pool.randomElement()!, near: tip)
            }
        }
        return combo
    }

    var anchor: CGPoint?                  // when set (stick mode), bubbles appear by the cowboy's head
    func say(_ text: String, near p0: CGPoint) {
        let p = anchor ?? p0
        bubble = (text, CGPoint(x: p.x + 14, y: p.y + 30), 0)
    }

    func step() {
        for i in popups.indices.reversed() {
            popups[i].age += 1
            popups[i].pos.y += 0.7
            if popups[i].age > 55 { popups.remove(at: i) }
        }
        for i in cracks.indices.reversed() {
            cracks[i].life -= 1.0 / (60.0 * 6.0)
            if cracks[i].life <= 0 { cracks.remove(at: i) }
        }
        if shakeFrames > 0 { shakeFrames -= 1 }
        if let b = bubble { bubble = b.age > 170 ? nil : (b.text, b.pos, b.age + 1) }
        motivation *= 0.9975
        meterAge += 1
    }

    static func font(_ size: CGFloat, heavy: Bool = true) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: heavy ? .heavy : .semibold)
        if let d = base.fontDescriptor.withDesign(.rounded) { return NSFont(descriptor: d, size: size) ?? base }
        return base
    }

    func bubbleRect() -> CGRect? {
        guard let b = bubble else { return nil }
        let sz = (b.text as NSString).size(withAttributes: [.font: Effects.font(12, heavy: false)])
        return CGRect(x: b.pos.x, y: b.pos.y, width: sz.width + 20, height: sz.height + 12)
    }

    func meterRect(hand: CGPoint) -> CGRect { CGRect(x: hand.x + 16, y: hand.y - 40, width: 132, height: 22) }

    func rects(hand: CGPoint) -> [CGRect] {
        var r = popups.map { CGRect(x: $0.pos.x - 100, y: $0.pos.y - 10, width: 200, height: 45) }
        for c in cracks {
            let rad = 36 * c.scale
            r.append(CGRect(x: c.p.x - rad, y: c.p.y - rad, width: rad * 2, height: rad * 2))
        }
        if let b = bubbleRect() { r.append(b.insetBy(dx: -6, dy: -14)) }
        if meterAge < 200 { r.append(meterRect(hand: hand).insetBy(dx: -4, dy: -4)) }
        return r
    }
}

// MARK: - Sound

final class CrackSound {
    var player: AVAudioPlayer?

    init(crackAt: Double) {
        let rate = 44100
        let total = Int(Double(rate) * (crackAt + 0.3))
        let c = Int(Double(rate) * crackAt)
        let perMs = Float(rate) / 1000
        var s = [Float](repeating: 0, count: total)
        var lp: Float = 0, lp2: Float = 0
        for i in 0..<c {
            let t = Float(i) / Float(c)
            lp += (0.03 + 0.3 * t) * (Float.random(in: -1...1) - lp)
            lp2 += 0.02 * (lp - lp2)
            s[i] = (lp - lp2) * 0.6 * t * t
        }
        var prev: Float = 0
        for j in 0..<(total - c) {
            let tm = Float(j) / perMs
            var v: Float = 0
            if tm < 0.5 { v += 1.0 } else if tm < 1.1 { v -= 0.85 }
            let noise = Float.random(in: -1...1)
            v += (noise - prev) * 0.7 * expf(-tm / 6)
            v += sinf(2 * Float.pi * 140 * Float(j) / Float(rate)) * 0.35 * expf(-tm / 20)
            prev = noise
            s[c + j] += v
        }
        var tl: Float = 0
        for j in 0..<(total - c) {
            let tm = Float(j) / perMs
            tl += 0.15 * (Float.random(in: -1...1) - tl)
            s[c + j] += tl * 0.15 * expf(-tm / 45) * min(1, tm / 2)
        }
        let peak = max(s.map { abs($0) }.max() ?? 1, 0.0001)
        var data = Data()
        func str(_ x: String) { data.append(contentsOf: Array(x.utf8)) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        str("RIFF"); u32(UInt32(36 + total * 2)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        str("data"); u32(UInt32(total * 2))
        for v in s {
            let x = Int16(max(-1, min(1, v / peak * 0.95)) * 32767)
            withUnsafeBytes(of: x.littleEndian) { data.append(contentsOf: $0) }
        }
        player = try? AVAudioPlayer(data: data)
        player?.prepareToPlay()
    }

    var slapPlayer: AVAudioPlayer?
    var heliPlayer: AVAudioPlayer?
    let heliSpeech = AVSpeechSynthesizer()
    var lastHeliChant = Date.distantPast

    func buildHelicopter() {
        let rate = 44100
        // 0.36s seamless loop containing 3 rotor blade passes (~8.3 Hz base chop, ramps up with rate)
        let dur = 0.36
        let total = Int(Double(rate) * dur)
        var s = [Float](repeating: 0, count: total)
        let blades = 3.0
        for i in 0..<total {
            let t = Double(i) / Double(rate)
            let phase = (t / dur) * blades
            let frac = phase - floor(phase) // 0...1 per blade pass
            // Low-frequency pressure thump per blade pass + airy whoosh envelope
            let bladeEnv = pow(sin(.pi * frac), 2.2)
            let subThump = sin(2.0 * .pi * (42.0 + 28.0 * sin(.pi * frac)) * t) * bladeEnv * 0.95
            let midChop = sin(2.0 * .pi * 115.0 * t) * pow(sin(.pi * frac), 4.0) * 0.35
            let airNoise = Float.random(in: -1...1) * Float(pow(sin(.pi * frac), 1.6)) * 0.42
            // Turbine whine undertone
            let turbine = sin(2.0 * .pi * 420.0 * t) * 0.08
            s[i] = Float(subThump + midChop + turbine) + airNoise
        }
        // Simple 1-pole lowpass so the air noise sounds like heavy rotor blades instead of static
        var lp: Float = 0
        for i in 0..<total {
            lp += 0.14 * (s[i] - lp)
            s[i] = lp
        }
        let peak = max(s.map { abs($0) }.max() ?? 1, 0.0001)
        var data = Data()
        func str(_ x: String) { data.append(contentsOf: Array(x.utf8)) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        str("RIFF"); u32(UInt32(36 + total * 2)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        str("data"); u32(UInt32(total * 2))
        for v in s {
            let x = Int16(max(-1, min(1, v / peak * 0.92)) * 32767)
            withUnsafeBytes(of: x.littleEndian) { data.append(contentsOf: $0) }
        }
        heliPlayer = try? AVAudioPlayer(data: data)
        heliPlayer?.numberOfLoops = -1
        heliPlayer?.enableRate = true
        heliPlayer?.prepareToPlay()
    }

    func startHelicopter(chant: Bool = true) {
        if let hp = heliPlayer {
            hp.rate = 0.85
            hp.volume = 0.9
            if !hp.isPlaying {
                hp.currentTime = 0
                hp.play()
            }
        }
        // rotor sound only — no voice
    }

    func updateHelicopter(charge: CGFloat) {
        guard let hp = heliPlayer, hp.isPlaying else { return }
        // Rotor speeds up from 0.85x to 1.85x as charge builds!
        hp.rate = Float(0.85 + charge * 1.0)
    }

    func stopHelicopter() {
        heliPlayer?.stop()
        if heliSpeech.isSpeaking {
            heliSpeech.stopSpeaking(at: .immediate)
        }
    }

    func buildSlap(crackAt: Double) {
        let rate = 44100
        let total = Int(Double(rate) * (crackAt + 0.35))
        let c = Int(Double(rate) * crackAt)
        var s = [Float](repeating: 0, count: total)
        // Whoosh before impact
        for i in 0..<c {
            let t = Float(i) / Float(c)
            s[i] = Float.random(in: -1...1) * 0.25 * t * t * sinf(2 * .pi * 220 * Float(i) / Float(rate))
        }
        // Meaty low-end thump + wet slap transient + cartoon pitch boing
        for j in 0..<(total - c) {
            let t = Float(j) / Float(rate)
            let env = expf(-t * 28.0)
            let thump = sinf(2 * .pi * (110.0 * expf(-t * 14.0) + 45.0) * t) * 1.2 * env
            let slapNoise = Float.random(in: -1...1) * expf(-t * 75.0) * 0.9
            let boing = sinf(2 * .pi * (260.0 + sinf(t * 55.0) * 60.0) * t) * expf(-t * 12.0) * 0.35
            s[c + j] = thump + slapNoise + boing
        }
        let peak = max(s.map { abs($0) }.max() ?? 1, 0.0001)
        var data = Data()
        func str(_ x: String) { data.append(contentsOf: Array(x.utf8)) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        str("RIFF"); u32(UInt32(36 + total * 2)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        str("data"); u32(UInt32(total * 2))
        for v in s {
            let x = Int16(max(-1, min(1, v / peak * 0.95)) * 32767)
            withUnsafeBytes(of: x.littleEndian) { data.append(contentsOf: $0) }
        }
        slapPlayer = try? AVAudioPlayer(data: data)
        slapPlayer?.prepareToPlay()
    }

    func play(wetSlap: Bool = false) {
        if wetSlap, let slapPlayer {
            slapPlayer.currentTime = 0
            slapPlayer.play()
            return
        }
        guard let player else { NSSound.beep(); return }
        player.currentTime = 0
        player.play()
    }
}

// MARK: - Drawing

enum Skin: Int { case leather, neon, gold, rainbow }

final class OverlayView: NSView {
    weak var whip: Whip?
    weak var fx: Effects?
    weak var buddy: Buddy?
    weak var stick: StickMan?
    var styleMode: Int = 1
    var skin: Skin = .leather
    var time: CGFloat = 0

    func color(_ i: Int, _ n: Int) -> NSColor {
        switch skin {
        case .leather: return NSColor(white: 0.04, alpha: 1)
        case .neon: return NSColor(calibratedRed: 0.25, green: 0.95, blue: 1, alpha: 1)
        case .gold: return NSColor(calibratedRed: 0.86, green: 0.66, blue: 0.22, alpha: 1)
        case .rainbow:
            let h = (CGFloat(i) / CGFloat(n) + time * 0.4).truncatingRemainder(dividingBy: 1)
            return NSColor(calibratedHue: h, saturation: 0.85, brightness: 1, alpha: 1)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let win = window else { return }
        ctx.clear(dirtyRect)
        guard let whip, let fx else { return }
        ctx.translateBy(x: -win.frame.minX, y: -win.frame.minY)
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        let S = whip.S
        let p = whip.pts, n = p.count
        func width(_ i: Int) -> CGFloat {
            (i >= n - whip.fall ? 0.5 : 2.1 * pow(1 - CGFloat(i) / CGFloat(n), 0.8) + 0.5) * S
        }
        func seg(_ i: Int) { ctx.move(to: CGPoint(x: p[i - 1].x, y: p[i - 1].y)); ctx.addLine(to: CGPoint(x: p[i].x, y: p[i].y)) }

        if styleMode == 1, let st = stick { drawStickBody(ctx, st) }
        else if styleMode == 0, let b = buddy, b.visible { drawBuddyBody(ctx, b, S: S) }
        else if styleMode == 3, let b = buddy { drawCursorStickBody(ctx, b, S: S) }

        // Screen shake offset on high combos
        if fx.shakeFrames > 0 {
            let sx = CGFloat.random(in: -fx.shakeIntensity...fx.shakeIntensity)
            let sy = CGFloat.random(in: -fx.shakeIntensity...fx.shakeIntensity)
            ctx.translateBy(x: sx, y: sy)
        }

        // Draw screen glass cracks from heavy impacts
        drawScreenCracks(ctx, fx: fx)

        // outline / glow
        if skin == .neon || skin == .rainbow {
            for i in 1..<n {
                ctx.setStrokeColor(color(i, n).withAlphaComponent(0.22).cgColor)
                ctx.setLineWidth(width(i) + 5 * S); seg(i); ctx.strokePath()
            }
        } else {
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.25).cgColor)
            for i in 1..<n { ctx.setLineWidth(width(i) + 0.9 * S); seg(i); ctx.strokePath() }
        }
        for i in 1..<n { ctx.setStrokeColor(color(i, n).cgColor); ctx.setLineWidth(width(i)); seg(i); ctx.strokePath() }

        // braid
        let braid: NSColor = skin == .gold ? NSColor(calibratedRed: 1, green: 0.92, blue: 0.6, alpha: 0.6) : NSColor.white.withAlphaComponent(0.16)
        ctx.setStrokeColor(braid.cgColor); ctx.setLineWidth(0.4 * S)
        for i in 1..<(n - whip.fall) {
            let dx = p[i].x - p[i - 1].x, dy = p[i].y - p[i - 1].y, d = max(hypot(dx, dy), 0.001)
            let tx = dx / d, ty = dy / d
            let ddx = (tx - ty) * 0.707, ddy = (ty + tx) * 0.707
            let w = width(i) * 0.5
            for f in [CGFloat(0.25), 0.75] {
                let mx = p[i - 1].x + dx * f, my = p[i - 1].y + dy * f
                ctx.move(to: CGPoint(x: mx - ddx * w, y: my - ddy * w)); ctx.addLine(to: CGPoint(x: mx + ddx * w, y: my + ddy * w))
            }
        }
        ctx.strokePath()

        // cracker
        let t = p[n - 1], t2 = p[n - 2]
        let ang = atan2(t.y - t2.y, t.x - t2.x)
        ctx.setStrokeColor(NSColor(white: 0.9, alpha: 0.9).cgColor); ctx.setLineWidth(0.4 * S)
        for off in [CGFloat(-0.35), 0, 0.3] {
            let a = ang + off, l: CGFloat = (off == 0 ? 4 : 3) * S
            ctx.move(to: CGPoint(x: t.x, y: t.y)); ctx.addLine(to: CGPoint(x: t.x + cos(a) * l, y: t.y + sin(a) * l))
        }
        ctx.strokePath()

        // handle
        ctx.saveGState()
        ctx.translateBy(x: p[0].x, y: p[0].y)
        ctx.rotate(by: atan2(p[1].y - p[0].y, p[1].x - p[0].x) + .pi)
        ctx.scaleBy(x: S, y: S)
        let grip = CGPath(roundedRect: CGRect(x: 0, y: -1.8, width: 15, height: 3.6), cornerWidth: 1.6, cornerHeight: 1.6, transform: nil)
        let gripColor: NSColor = skin == .gold ? NSColor(calibratedRed: 0.35, green: 0.2, blue: 0.08, alpha: 1) : NSColor(white: 0.06, alpha: 1)
        ctx.addPath(grip); ctx.setFillColor(gripColor.cgColor); ctx.fillPath()
        ctx.addPath(grip); ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.25).cgColor); ctx.setLineWidth(0.5); ctx.strokePath()
        ctx.setFillColor((skin == .gold ? NSColor(calibratedRed: 1, green: 0.8, blue: 0.3, alpha: 1) : NSColor(white: 0.45, alpha: 1)).cgColor)
        ctx.fill(CGRect(x: 0, y: -1.8, width: 1.3, height: 3.6))
        ctx.setFillColor(gripColor.cgColor)
        ctx.fillEllipse(in: CGRect(x: 13.5, y: -2.3, width: 4.6, height: 4.6))
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.25).cgColor)
        ctx.strokeEllipse(in: CGRect(x: 13.5, y: -2.3, width: 4.6, height: 4.6))
        ctx.restoreGState()

        // shock ring + puffs
        if let r = whip.ring {
            let rad = (1.5 + r.age * 1.8) * S
            let c = skin == .leather ? NSColor.white : color(n - 1, n)
            ctx.setStrokeColor(c.withAlphaComponent(0.7 * (1 - r.age / 9)).cgColor); ctx.setLineWidth(1)
            ctx.strokeEllipse(in: CGRect(x: r.x - rad, y: r.y - rad, width: rad * 2, height: rad * 2))
        }
        for s in whip.puffs {
            let c = skin == .leather ? NSColor(white: 0.9, alpha: 1) : color(Int.random(in: 0..<n), n)
            ctx.setFillColor(c.withAlphaComponent(0.55 * s.life).cgColor)
            let rad = (0.7 + (1 - s.life)) * S
            ctx.fillEllipse(in: CGRect(x: s.x - rad, y: s.y - rad, width: rad * 2, height: rad * 2))
        }

        if styleMode == 1, let st = stick { drawStickArm(ctx, st) }
        else if styleMode == 0, let b = buddy, b.visible { drawBuddyArm(ctx, b, hand: CGPoint(x: p[0].x, y: p[0].y), S: S) }
        else if styleMode == 3, let b = buddy { drawCursorStickArm(ctx, b, hand: CGPoint(x: p[0].x, y: p[0].y), S: S) }
        drawEffects(fx, hand: whip.hand)
    }

    func drawScreenCracks(_ ctx: CGContext, fx: Effects) {
        for c in fx.cracks {
            ctx.saveGState()
            ctx.translateBy(x: c.p.x, y: c.p.y)
            ctx.rotate(by: c.rot)
            ctx.scaleBy(x: c.scale, y: c.scale)
            let a = min(1, c.life * 2.5)
            let web = CGMutablePath()
            for i in 0..<9 {
                let ang = CGFloat(i) * (.pi * 2 / 9) + sin(CGFloat(i)) * 0.2
                let len: CGFloat = 18 + CGFloat(i % 3) * 11
                web.move(to: CGPoint(x: cos(ang) * 3, y: sin(ang) * 3))
                let mid = CGPoint(x: cos(ang + 0.12) * (len * 0.55), y: sin(ang + 0.12) * (len * 0.55))
                web.addLine(to: mid)
                web.addLine(to: CGPoint(x: cos(ang - 0.08) * len, y: sin(ang - 0.08) * len))
            }
            ctx.addPath(web)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.65 * a).cgColor)
            ctx.setLineWidth(1.2)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    /// Hand-drawn style line: a soft white halo (visible on dark mode) under a black stroke.
    func inkLine(_ ctx: CGContext, _ path: CGPath, width: CGFloat) {
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.addPath(path); ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.75).cgColor); ctx.setLineWidth(width + 3); ctx.strokePath()
        ctx.addPath(path); ctx.setStrokeColor(NSColor(white: 0.05, alpha: 1).cgColor); ctx.setLineWidth(width); ctx.strokePath()
    }

    func drawStickBody(_ ctx: CGContext, _ st: StickMan) {
        // tumbleweed rolling across the bottom of the window (world space)
        if let w = st.weedCenter, let rot = st.weed?.rot {
            ctx.saveGState()
            ctx.translateBy(x: w.x, y: w.y); ctx.rotate(by: rot); ctx.scaleBy(x: st.scale, y: st.scale)
            let tw = CGMutablePath()
            for i in 0..<8 {
                let a = CGFloat(i) * 0.8
                tw.addEllipse(in: CGRect(x: -12 + cos(a) * 3, y: -9 + sin(a) * 3, width: 24 - CGFloat(i % 3) * 3, height: 18 + CGFloat(i % 2) * 4),
                              transform: CGAffineTransform(rotationAngle: a))
            }
            ctx.addPath(tw); ctx.setStrokeColor(NSColor(calibratedRed: 0.55, green: 0.4, blue: 0.2, alpha: 0.9).cgColor)
            ctx.setLineWidth(1.3); ctx.strokePath()
            ctx.restoreGState()
        }

        ctx.saveGState()
        ctx.translateBy(x: st.feet.x, y: st.feet.y)
        ctx.scaleBy(x: st.scale * st.sgn, y: st.scale)
        ctx.setFillColor(NSColor(white: 0, alpha: 0.16).cgColor)
        ctx.fillEllipse(in: CGRect(x: -34, y: -5 - st.jump, width: 68, height: 9))      // shadow stays on the ground

        let L = st.lift
        let hip = CGPoint(x: 0, y: 48 - L)
        let legs = CGMutablePath()
        if st.sit > 0.5 {                                                                 // sitting, knees up
            legs.move(to: hip); legs.addLine(to: CGPoint(x: 15, y: 18)); legs.addLine(to: CGPoint(x: 25, y: 0))
            legs.move(to: hip); legs.addLine(to: CGPoint(x: 8, y: 15)); legs.addLine(to: CGPoint(x: 17, y: 0))
        } else if st.walking {                                                            // walking stride
            let a = sin(st.gait) * 14
            legs.move(to: CGPoint(x: -a, y: max(0, cos(st.gait)) * 6)); legs.addLine(to: hip)
            legs.addLine(to: CGPoint(x: a, y: max(0, -cos(st.gait)) * 6))
        } else {
            let tap = st.tapping ? max(0, sin(st.t * 13)) * 6 : 0
            let spread: CGFloat = st.squint > 0 ? 4 : 0
            legs.move(to: CGPoint(x: -20 - spread, y: 0)); legs.addLine(to: hip); legs.addLine(to: CGPoint(x: 20 + spread, y: tap))
        }
        legs.move(to: hip); legs.addLine(to: CGPoint(x: 0, y: 97 - L))                   // body
        // free arm
        let sh = CGPoint(x: 0, y: 88 - L)
        let freeHand: CGPoint
        if st.showsGun {
            freeHand = st.gunHandL
            legs.move(to: sh); legs.addLine(to: CGPoint(x: 16, y: 90 - L)); legs.addLine(to: freeHand)
        } else if st.mood == .celebrate {
            freeHand = CGPoint(x: -6, y: 134 - L)
            legs.move(to: sh); legs.addLine(to: CGPoint(x: -12, y: 112 - L)); legs.addLine(to: freeHand)
        } else if st.mood == .idle, st.act == .tipHat {
            freeHand = CGPoint(x: 6, y: 128 - L)                                              // hand to the hat brim
            legs.move(to: sh); legs.addLine(to: CGPoint(x: 14, y: 106 - L)); legs.addLine(to: freeHand)
        } else if st.sit > 0.5 {
            freeHand = CGPoint(x: 15, y: 22)
            legs.move(to: sh); legs.addLine(to: CGPoint(x: 8, y: 36)); legs.addLine(to: freeHand)
        } else {
            freeHand = CGPoint(x: -7, y: 50 - L)
            legs.move(to: sh); legs.addLine(to: CGPoint(x: -13, y: 68 - L)); legs.addLine(to: freeHand)
        }
        inkLine(ctx, legs, width: 3.2)

        // six-shooter
        if st.showsGun {
            let h = freeHand
            let gun = CGMutablePath()
            gun.addRect(CGRect(x: h.x - 1, y: h.y + 1, width: 18, height: 4.5))                 // barrel
            gun.addRect(CGRect(x: h.x - 2, y: h.y - 6, width: 5, height: 9))                    // grip
            gun.addEllipse(in: CGRect(x: h.x + 2, y: h.y - 0.5, width: 6, height: 6))          // cylinder
            ctx.addPath(gun); ctx.setFillColor(NSColor(white: 0.25, alpha: 1).cgColor); ctx.fillPath()
            inkLine(ctx, gun, width: 1.2)
            if st.flash > 0.05 {                                                              // muzzle flash
                let m = st.muzzleL
                let star = CGMutablePath()
                for i in 0..<10 {
                    let a = CGFloat(i) * .pi / 5, r: CGFloat = (i % 2 == 0 ? 13 : 5) * st.flash + 2
                    let pt = CGPoint(x: m.x + 4 + cos(a) * r, y: m.y + sin(a) * r)
                    if i == 0 { star.move(to: pt) } else { star.addLine(to: pt) }
                }
                star.closeSubpath()
                ctx.addPath(star); ctx.setFillColor(NSColor(calibratedRed: 1, green: 0.85, blue: 0.3, alpha: st.flash).cgColor); ctx.fillPath()
            }
        }

        // campfire while he naps at night
        if st.sit > 0.3, st.night {
            let fx0: CGFloat = 46
            ctx.setFillColor(NSColor(calibratedRed: 1, green: 0.55, blue: 0.15, alpha: 0.18 * st.sit).cgColor)
            ctx.fillEllipse(in: CGRect(x: fx0 - 34, y: -14, width: 68, height: 40))           // warm glow
            let logs = CGMutablePath()
            logs.move(to: CGPoint(x: fx0 - 13, y: 0)); logs.addLine(to: CGPoint(x: fx0 + 13, y: 6))
            logs.move(to: CGPoint(x: fx0 - 13, y: 6)); logs.addLine(to: CGPoint(x: fx0 + 13, y: 0))
            ctx.addPath(logs); ctx.setStrokeColor(NSColor(white: 0.05, alpha: 1).cgColor); ctx.setLineWidth(5.5); ctx.strokePath()
            ctx.addPath(logs); ctx.setStrokeColor(NSColor(calibratedRed: 0.5, green: 0.3, blue: 0.15, alpha: 1).cgColor); ctx.setLineWidth(3.5); ctx.strokePath()
            for (i, col) in [NSColor(calibratedRed: 1, green: 0.4, blue: 0.1, alpha: 1),
                             NSColor(calibratedRed: 1, green: 0.65, blue: 0.15, alpha: 1),
                             NSColor(calibratedRed: 1, green: 0.9, blue: 0.45, alpha: 1)].enumerated() {
                let k = CGFloat(i)
                let hgt = (26 - k * 7) * (0.85 + 0.15 * sin(st.flame * (1.3 + k * 0.4) + k))
                let w = 11 - k * 3
                let sway = sin(st.flame * 0.9 + k) * 2.5
                let f = CGMutablePath()
                f.move(to: CGPoint(x: fx0 - w, y: 4))
                f.addQuadCurve(to: CGPoint(x: fx0 + sway, y: 4 + hgt), control: CGPoint(x: fx0 - w * 1.1, y: 4 + hgt * 0.55))
                f.addQuadCurve(to: CGPoint(x: fx0 + w, y: 4), control: CGPoint(x: fx0 + w * 1.1, y: 4 + hgt * 0.55))
                f.closeSubpath()
                ctx.addPath(f); ctx.setFillColor(col.withAlphaComponent(st.sit).cgColor); ctx.fillPath()
            }
            for i in 0..<4 {                                                                  // sparks drifting up
                let ph = (st.flame * 0.12 + CGFloat(i) * 0.25).truncatingRemainder(dividingBy: 1)
                ctx.setFillColor(NSColor(calibratedRed: 1, green: 0.8, blue: 0.4, alpha: (1 - ph) * st.sit).cgColor)
                ctx.fillEllipse(in: CGRect(x: fx0 + sin(ph * 9 + CGFloat(i)) * 6, y: 28 + ph * 40, width: 2.2, height: 2.2))
            }
        }

        // lasso spinning above his head while he celebrates
        if st.mood == .celebrate, !st.gunCelebration {
            let c = CGPoint(x: 0, y: 152 - L)
            let knot = CGPoint(x: c.x + cos(st.lasso) * 30, y: c.y + sin(st.lasso) * 9)
            let rope = CGMutablePath()
            rope.addEllipse(in: CGRect(x: c.x - 30, y: c.y - 9, width: 60, height: 18))
            rope.move(to: freeHand); rope.addQuadCurve(to: knot, control: CGPoint(x: (freeHand.x + knot.x) / 2, y: freeHand.y + 4))
            ctx.addPath(rope); ctx.setStrokeColor(NSColor(white: 0.05, alpha: 1).cgColor); ctx.setLineWidth(3.4); ctx.strokePath()
            ctx.addPath(rope); ctx.setStrokeColor(NSColor(calibratedRed: 0.85, green: 0.7, blue: 0.45, alpha: 1).cgColor); ctx.setLineWidth(1.8); ctx.strokePath()
        }

        // head
        let hc = st.headL
        ctx.addEllipse(in: CGRect(x: hc.x - 15, y: hc.y - 15, width: 30, height: 30))
        ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
        inkLine(ctx, CGPath(ellipseIn: CGRect(x: hc.x - 15, y: hc.y - 15, width: 30, height: 30), transform: nil), width: 3)

        // face
        let y0 = hc.y
        let face = CGMutablePath()
        if st.mood == .sleeping {
            face.move(to: CGPoint(x: 0, y: y0 + 2)); face.addQuadCurve(to: CGPoint(x: 5, y: y0 + 2), control: CGPoint(x: 2.5, y: y0))
            face.move(to: CGPoint(x: 7, y: y0 + 2)); face.addQuadCurve(to: CGPoint(x: 12, y: y0 + 2), control: CGPoint(x: 9.5, y: y0))
            face.addEllipse(in: CGRect(x: 4, y: y0 - 8, width: 3.5, height: 3.5))
        } else if st.squint > 0 {
            face.move(to: CGPoint(x: -1, y: y0 + 5)); face.addLine(to: CGPoint(x: 4, y: y0 + 2)); face.addLine(to: CGPoint(x: -1, y: y0 - 1))
            face.move(to: CGPoint(x: 12, y: y0 + 5)); face.addLine(to: CGPoint(x: 7, y: y0 + 2)); face.addLine(to: CGPoint(x: 12, y: y0 - 1))
            face.addEllipse(in: CGRect(x: 3, y: y0 - 11, width: 6, height: 5))
        } else {
            // pupils look at your cursor
            let hw = st.head
            let ex = max(-2.5, min(2.5, (st.mouse.x - hw.x) * st.sgn / 120)), ey = max(-2, min(2.5, (st.mouse.y - hw.y) / 120))
            if st.air != nil {                                                           // O_O
                face.addEllipse(in: CGRect(x: -0.5, y: y0, width: 5, height: 5.5))
                face.addEllipse(in: CGRect(x: 7, y: y0, width: 5, height: 5.5))
            } else {
                face.addEllipse(in: CGRect(x: 1 + ex, y: y0 + 1 + ey, width: 2.5, height: 3))
                face.addEllipse(in: CGRect(x: 8 + ex, y: y0 + 1 + ey, width: 2.5, height: 3))
            }
            if st.air != nil {
                face.addEllipse(in: CGRect(x: 3, y: y0 - 11, width: 6, height: 6))     // screaming
            } else if st.mood == .celebrate {                                                  // big grin
                face.move(to: CGPoint(x: 0, y: y0 - 5)); face.addQuadCurve(to: CGPoint(x: 11, y: y0 - 5), control: CGPoint(x: 5.5, y: y0 - 13))
                face.addLine(to: CGPoint(x: 0, y: y0 - 5))
            } else if st.mood == .waiting {                                             // grumpy brows, flat mouth
                face.move(to: CGPoint(x: -1, y: y0 + 8)); face.addLine(to: CGPoint(x: 4, y: y0 + 6.5))
                face.move(to: CGPoint(x: 12, y: y0 + 8)); face.addLine(to: CGPoint(x: 7, y: y0 + 6.5))
                face.move(to: CGPoint(x: 2, y: y0 - 7)); face.addLine(to: CGPoint(x: 9, y: y0 - 7))
            } else {
                face.move(to: CGPoint(x: 1, y: y0 - 6)); face.addQuadCurve(to: CGPoint(x: 10, y: y0 - 6), control: CGPoint(x: 5.5, y: y0 - 10))
            }
        }
        ctx.addPath(face); ctx.setStrokeColor(NSColor(white: 0.05, alpha: 1).cgColor); ctx.setLineWidth(2); ctx.strokePath()

        // cowboy hat (tipped over his eyes when asleep, tossed on celebrations)
        ctx.saveGState()
        let tip: CGFloat = (st.mood == .idle && st.act == .tipHat) ? sin(min(1, st.actT / 1.2) * .pi) * 6 : 0
        ctx.translateBy(x: st.sit > 0.5 ? 3 : 0, y: hc.y + 12 + st.hop * 18 + tip - (st.sit > 0.5 ? 5 : 0))
        ctx.rotate(by: st.hop * 0.5 - (st.sit > 0.5 ? 0.3 : 0))
        let hat = hatColor()
        let crown = CGMutablePath()
        crown.move(to: CGPoint(x: -11, y: 2)); crown.addLine(to: CGPoint(x: -10, y: 15))
        crown.addQuadCurve(to: CGPoint(x: 0, y: 13), control: CGPoint(x: -5, y: 18))
        crown.addQuadCurve(to: CGPoint(x: 10, y: 15), control: CGPoint(x: 5, y: 18))
        crown.addLine(to: CGPoint(x: 11, y: 2)); crown.closeSubpath()
        ctx.addPath(crown); ctx.setFillColor(hat.cgColor); ctx.fillPath()
        inkLine(ctx, crown, width: 2)
        let brim = CGMutablePath()
        brim.move(to: CGPoint(x: -22, y: 5))
        brim.addQuadCurve(to: CGPoint(x: 22, y: 5), control: CGPoint(x: 0, y: -5))
        brim.addQuadCurve(to: CGPoint(x: -22, y: 5), control: CGPoint(x: 0, y: 2))
        brim.closeSubpath()
        ctx.addPath(brim); ctx.setFillColor(hat.cgColor); ctx.fillPath()
        inkLine(ctx, brim, width: 2)
        ctx.restoreGState()
        ctx.restoreGState()

        // Zzz while he naps (world space so the letters aren't mirrored)
        if st.mood == .sleeping {
            for i in 0..<3 {
                let ph = (st.moodT * 0.5 + CGFloat(i) / 3).truncatingRemainder(dividingBy: 1)
                let p = CGPoint(x: st.head.x + (14 + ph * 16) * st.scale, y: st.head.y + (12 + ph * 34) * st.scale)
                let attrs: [NSAttributedString.Key: Any] = [.font: Effects.font((9 + ph * 9) * st.scale),
                                                            .foregroundColor: NSColor(white: 0.1, alpha: sin(ph * .pi)),
                                                            .strokeColor: NSColor(white: 1, alpha: 0.8 * sin(ph * .pi)), .strokeWidth: -3]
                ("z" as NSString).draw(at: p, withAttributes: attrs)
            }
        }

        // whistled music notes
        for n in st.notes {
            let attrs: [NSAttributedString.Key: Any] = [.font: Effects.font(13 * st.scale),
                                                        .foregroundColor: NSColor(white: 0.1, alpha: n.life),
                                                        .strokeColor: NSColor(white: 1, alpha: 0.8 * n.life), .strokeWidth: -3]
            (n.glyph as NSString).draw(at: CGPoint(x: n.x, y: n.y), withAttributes: attrs)
        }

        if let b = st.bandit { drawBandit(ctx, st, b) }
        if let u = st.ufo { drawUFO(ctx, st, u) }

        // bullet holes in the Claude window (they heal after a few seconds)
        for h in st.holes {
            ctx.saveGState()
            ctx.translateBy(x: h.p.x, y: h.p.y); ctx.rotate(by: h.rot)
            let a = min(1, h.life * 3)
            let cracks = CGMutablePath()
            for i in 0..<7 {
                let ang = CGFloat(i) * 0.9, len: CGFloat = 9 + CGFloat(i % 3) * 4
                cracks.move(to: CGPoint(x: cos(ang) * 4, y: sin(ang) * 4))
                cracks.addLine(to: CGPoint(x: cos(ang + 0.15) * len, y: sin(ang + 0.15) * len))
            }
            ctx.addPath(cracks); ctx.setStrokeColor(NSColor(white: 0.5, alpha: 0.8 * a).cgColor); ctx.setLineWidth(0.8); ctx.strokePath()
            ctx.setFillColor(NSColor(white: 0.08, alpha: a).cgColor)
            ctx.fillEllipse(in: CGRect(x: -4.5, y: -4.5, width: 9, height: 9))
            ctx.setStrokeColor(NSColor(white: 0.85, alpha: 0.7 * a).cgColor); ctx.setLineWidth(1)
            ctx.strokeEllipse(in: CGRect(x: -5.5, y: -5.5, width: 11, height: 11))
            ctx.restoreGState()
        }

        // confetti
        for c in st.confetti {
            ctx.saveGState()
            ctx.translateBy(x: c.x, y: c.y); ctx.rotate(by: c.rot)
            ctx.setFillColor(c.color.withAlphaComponent(min(1, c.life * 2)).cgColor)
            ctx.fill(CGRect(x: -3, y: -1.5, width: 6, height: 3))
            ctx.restoreGState()
        }
    }

    /// The rival: black hat, red bandana, faces the cowboy, loses every time.
    func drawBandit(_ ctx: CGContext, _ st: StickMan, _ b: (x: CGFloat, phase: Int, t: CGFloat, fall: CGFloat, hatY: CGFloat)) {
        ctx.saveGState()
        ctx.translateBy(x: b.x, y: st.home.y)
        ctx.rotate(by: -b.fall * .pi / 2 * 0.92)                       // topples backwards
        ctx.scaleBy(x: -st.scale, y: st.scale)                          // faces left, toward the cowboy
        if b.phase == 4 { ctx.setAlpha(max(0, 1 - b.t)) }
        let legs = CGMutablePath()
        let hip = CGPoint(x: 0, y: 48)
        if b.phase == 0 {
            let g = b.t * 12, a = sin(g) * 14
            legs.move(to: CGPoint(x: -a, y: max(0, cos(g)) * 6)); legs.addLine(to: hip); legs.addLine(to: CGPoint(x: a, y: max(0, -cos(g)) * 6))
        } else {
            legs.move(to: CGPoint(x: -22, y: 0)); legs.addLine(to: hip); legs.addLine(to: CGPoint(x: 22, y: 0))
        }
        legs.move(to: hip); legs.addLine(to: CGPoint(x: 0, y: 97))
        legs.move(to: CGPoint(x: 0, y: 88)); legs.addLine(to: CGPoint(x: -13, y: 68)); legs.addLine(to: CGPoint(x: -7, y: 50))
        let gunHand = b.phase >= 2 ? CGPoint(x: 26, y: 92) : CGPoint(x: 12, y: 54)            // hand hovering over the holster
        legs.move(to: CGPoint(x: 0, y: 88)); legs.addLine(to: CGPoint(x: b.phase >= 2 ? 14 : 13, y: b.phase >= 2 ? 88 : 68)); legs.addLine(to: gunHand)
        inkLine(ctx, legs, width: 3.2)
        if b.phase >= 2 {
            let gun = CGMutablePath()
            gun.addRect(CGRect(x: gunHand.x - 1, y: gunHand.y + 1, width: 16, height: 4))
            gun.addRect(CGRect(x: gunHand.x - 2, y: gunHand.y - 6, width: 5, height: 9))
            ctx.addPath(gun); ctx.setFillColor(NSColor(white: 0.25, alpha: 1).cgColor); ctx.fillPath()
            inkLine(ctx, gun, width: 1.2)
        }
        // head, angry eyes, red bandana
        let hc = CGPoint(x: 0, y: 112)
        ctx.addEllipse(in: CGRect(x: hc.x - 15, y: hc.y - 15, width: 30, height: 30))
        ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
        inkLine(ctx, CGPath(ellipseIn: CGRect(x: hc.x - 15, y: hc.y - 15, width: 30, height: 30), transform: nil), width: 3)
        let face = CGMutablePath()
        if b.phase >= 3 {                                                                        // x_x
            for ex in [CGFloat(1), 8] {
                face.move(to: CGPoint(x: ex - 1.5, y: hc.y + 5)); face.addLine(to: CGPoint(x: ex + 2.5, y: hc.y + 1))
                face.move(to: CGPoint(x: ex + 2.5, y: hc.y + 5)); face.addLine(to: CGPoint(x: ex - 1.5, y: hc.y + 1))
            }
        } else {
            face.addEllipse(in: CGRect(x: 1, y: hc.y + 1, width: 2.5, height: 3))
            face.addEllipse(in: CGRect(x: 8, y: hc.y + 1, width: 2.5, height: 3))
            face.move(to: CGPoint(x: -1, y: hc.y + 9)); face.addLine(to: CGPoint(x: 4, y: hc.y + 6.5))
            face.move(to: CGPoint(x: 12, y: hc.y + 9)); face.addLine(to: CGPoint(x: 7, y: hc.y + 6.5))
        }
        ctx.addPath(face); ctx.setStrokeColor(NSColor(white: 0.05, alpha: 1).cgColor); ctx.setLineWidth(2); ctx.strokePath()
        let bandana = CGMutablePath()
        bandana.move(to: CGPoint(x: -13, y: hc.y - 2)); bandana.addLine(to: CGPoint(x: 15, y: hc.y - 2))
        bandana.addLine(to: CGPoint(x: 4, y: hc.y - 16)); bandana.closeSubpath()
        ctx.addPath(bandana); ctx.setFillColor(NSColor(calibratedRed: 0.8, green: 0.12, blue: 0.12, alpha: 1).cgColor); ctx.fillPath()
        inkLine(ctx, bandana, width: 1.4)
        // black hat (flies off when he's hit)
        ctx.saveGState()
        ctx.translateBy(x: b.hatY * 0.3, y: hc.y + 12 + b.hatY)
        ctx.rotate(by: b.hatY * 0.03)
        let crown = CGMutablePath()
        crown.move(to: CGPoint(x: -11, y: 2)); crown.addLine(to: CGPoint(x: -10, y: 16))
        crown.addLine(to: CGPoint(x: 10, y: 16)); crown.addLine(to: CGPoint(x: 11, y: 2)); crown.closeSubpath()
        crown.move(to: CGPoint(x: -22, y: 4)); crown.addQuadCurve(to: CGPoint(x: 22, y: 4), control: CGPoint(x: 0, y: -4))
        crown.addQuadCurve(to: CGPoint(x: -22, y: 4), control: CGPoint(x: 0, y: 2)); crown.closeSubpath()
        ctx.addPath(crown); ctx.setFillColor(NSColor(white: 0.08, alpha: 1).cgColor); ctx.fillPath()
        inkLine(ctx, crown, width: 1.6)
        ctx.restoreGState()
        ctx.restoreGState()
    }

    /// Flying saucer with blinking rim lights and a tractor beam.
    func drawUFO(_ ctx: CGContext, _ st: StickMan, _ u: (x: CGFloat, y: CGFloat, phase: Int, t: CGFloat)) {
        let S = st.scale
        if u.phase == 1 {
            let beam = CGMutablePath()
            beam.move(to: CGPoint(x: u.x - 10 * S, y: u.y - 6 * S)); beam.addLine(to: CGPoint(x: u.x + 10 * S, y: u.y - 6 * S))
            beam.addLine(to: CGPoint(x: u.x + 34 * S, y: st.home.y)); beam.addLine(to: CGPoint(x: u.x - 34 * S, y: st.home.y)); beam.closeSubpath()
            ctx.addPath(beam); ctx.setFillColor(NSColor(calibratedRed: 0.6, green: 1, blue: 0.6, alpha: 0.28).cgColor); ctx.fillPath()
        }
        ctx.saveGState()
        ctx.translateBy(x: u.x, y: u.y); ctx.scaleBy(x: S, y: S)
        ctx.rotate(by: u.phase == 2 ? 0.25 : sin(st.t * 2) * 0.06)
        let dome = CGPath(ellipseIn: CGRect(x: -13, y: 0, width: 26, height: 22), transform: nil)
        ctx.addPath(dome); ctx.setFillColor(NSColor(calibratedRed: 0.6, green: 0.9, blue: 1, alpha: 0.85).cgColor); ctx.fillPath()
        inkLine(ctx, dome, width: 2)
        let body = CGPath(ellipseIn: CGRect(x: -36, y: -8, width: 72, height: 18), transform: nil)
        ctx.addPath(body); ctx.setFillColor(NSColor(white: 0.75, alpha: 1).cgColor); ctx.fillPath()
        inkLine(ctx, body, width: 2.4)
        let colors: [NSColor] = [.systemRed, .systemYellow, .systemGreen, .systemBlue, .systemPink]
        for i in 0..<5 {
            let on = (Int(st.t * 6) + i) % 2 == 0
            ctx.setFillColor((on ? colors[i] : NSColor(white: 0.35, alpha: 1)).cgColor)
            ctx.fillEllipse(in: CGRect(x: -26 + CGFloat(i) * 12, y: -2, width: 4.5, height: 4.5))
        }
        ctx.restoreGState()
    }

    /// Stick cowboy whose whip hand IS your cursor: he flies after it, legs running in the air.
    func drawCursorStickBody(_ ctx: CGContext, _ b: Buddy, S: CGFloat) {
        let K = b.k(S), f: CGFloat = b.face >= 0 ? 1 : -1
        ctx.saveGState()
        ctx.translateBy(x: b.pos.x, y: b.pos.y)
        ctx.scaleBy(x: K * f, y: K)
        let speed = hypot(b.vel.dx, b.vel.dy)
        let hip = CGPoint(x: 0, y: 48)
        let legs = CGMutablePath()
        if speed > 0.8 {                                           // running through the air
            let a = sin(b.run) * 16
            legs.move(to: CGPoint(x: -a, y: max(0, cos(b.run)) * 8)); legs.addLine(to: hip)
            legs.addLine(to: CGPoint(x: a, y: max(0, -cos(b.run)) * 8))
        } else {                                                   // hovering, legs dangling
            let d = sin(b.bob * 1.3) * 3
            legs.move(to: CGPoint(x: -12 + d, y: 2)); legs.addLine(to: hip); legs.addLine(to: CGPoint(x: 12 - d, y: 2))
        }
        legs.move(to: hip); legs.addLine(to: CGPoint(x: 0, y: 97))
        legs.move(to: CGPoint(x: 0, y: 88)); legs.addLine(to: CGPoint(x: -13, y: 68)); legs.addLine(to: CGPoint(x: -7, y: 50))   // hand on hip
        inkLine(ctx, legs, width: 3.4)

        let hc = CGPoint(x: 0, y: 112)
        ctx.addEllipse(in: CGRect(x: hc.x - 15, y: hc.y - 15, width: 30, height: 30))
        ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
        inkLine(ctx, CGPath(ellipseIn: CGRect(x: hc.x - 15, y: hc.y - 15, width: 30, height: 30), transform: nil), width: 3.2)
        let face = CGMutablePath()
        if b.squint > 0 {
            face.move(to: CGPoint(x: -1, y: hc.y + 5)); face.addLine(to: CGPoint(x: 4, y: hc.y + 2)); face.addLine(to: CGPoint(x: -1, y: hc.y - 1))
            face.move(to: CGPoint(x: 12, y: hc.y + 5)); face.addLine(to: CGPoint(x: 7, y: hc.y + 2)); face.addLine(to: CGPoint(x: 12, y: hc.y - 1))
            face.addEllipse(in: CGRect(x: 3, y: hc.y - 11, width: 6, height: 5))
        } else {
            face.addEllipse(in: CGRect(x: 2, y: hc.y + 1, width: 2.5, height: 3))
            face.addEllipse(in: CGRect(x: 9, y: hc.y + 1, width: 2.5, height: 3))
            if speed > 6 {                                         // going fast: whoa face
                face.addEllipse(in: CGRect(x: 4, y: hc.y - 10, width: 5, height: 5))
            } else {
                face.move(to: CGPoint(x: 2, y: hc.y - 6)); face.addQuadCurve(to: CGPoint(x: 11, y: hc.y - 6), control: CGPoint(x: 6.5, y: hc.y - 10))
            }
        }
        ctx.addPath(face); ctx.setStrokeColor(NSColor(white: 0.05, alpha: 1).cgColor); ctx.setLineWidth(2.2); ctx.strokePath()

        // hat leans back with speed, flies up on combos
        ctx.saveGState()
        ctx.translateBy(x: 0, y: hc.y + 12 + b.hop * 18)
        ctx.rotate(by: min(0.5, speed * 0.03) + b.hop * 0.5)
        let hat = hatColor()
        let crown = CGMutablePath()
        crown.move(to: CGPoint(x: -11, y: 2)); crown.addLine(to: CGPoint(x: -10, y: 15))
        crown.addQuadCurve(to: CGPoint(x: 0, y: 13), control: CGPoint(x: -5, y: 18))
        crown.addQuadCurve(to: CGPoint(x: 10, y: 15), control: CGPoint(x: 5, y: 18))
        crown.addLine(to: CGPoint(x: 11, y: 2)); crown.closeSubpath()
        ctx.addPath(crown); ctx.setFillColor(hat.cgColor); ctx.fillPath()
        inkLine(ctx, crown, width: 2.2)
        let brim = CGMutablePath()
        brim.move(to: CGPoint(x: -22, y: 5))
        brim.addQuadCurve(to: CGPoint(x: 22, y: 5), control: CGPoint(x: 0, y: -5))
        brim.addQuadCurve(to: CGPoint(x: -22, y: 5), control: CGPoint(x: 0, y: 2))
        brim.closeSubpath()
        ctx.addPath(brim); ctx.setFillColor(hat.cgColor); ctx.fillPath()
        inkLine(ctx, brim, width: 2.2)
        ctx.restoreGState()
        ctx.restoreGState()
    }

    /// His whip arm reaches from the shoulder to your cursor, where his fist grips the handle.
    func drawCursorStickArm(_ ctx: CGContext, _ b: Buddy, hand: CGPoint, S: CGFloat) {
        let K = b.k(S), f: CGFloat = b.face >= 0 ? 1 : -1
        ctx.saveGState()
        ctx.translateBy(x: b.pos.x, y: b.pos.y)
        ctx.scaleBy(x: K * f, y: K)
        let local = CGPoint(x: (hand.x - b.pos.x) / K * f, y: (hand.y - b.pos.y) / K)
        let sh = CGPoint(x: 0, y: 88)
        let dx = local.x - sh.x, dy = local.y - sh.y, len = max(hypot(dx, dy), 0.001)
        let mid = CGPoint(x: (sh.x + local.x) / 2, y: (sh.y + local.y) / 2)
        let bend = max(0, 22 - len * 0.25)
        let elbow = CGPoint(x: mid.x + (dy / len) * bend, y: mid.y - (dx / len) * bend)
        let arm = CGMutablePath()
        arm.move(to: sh); arm.addLine(to: elbow); arm.addLine(to: local)
        inkLine(ctx, arm, width: 3.4)
        ctx.setFillColor(NSColor(white: 0.05, alpha: 1).cgColor)
        ctx.fillEllipse(in: CGRect(x: local.x - 4, y: local.y - 4, width: 8, height: 8))
        ctx.restoreGState()
    }

    func drawStickArm(_ ctx: CGContext, _ st: StickMan) {
        ctx.saveGState()
        ctx.translateBy(x: st.feet.x, y: st.feet.y)
        ctx.scaleBy(x: st.scale * st.sgn, y: st.scale)
        let p = CGMutablePath()
        p.move(to: st.shoulderL); p.addLine(to: st.elbowL); p.addLine(to: st.handL)
        inkLine(ctx, p, width: 3.2)
        ctx.setFillColor(NSColor(white: 0.05, alpha: 1).cgColor)
        ctx.fillEllipse(in: CGRect(x: st.handL.x - 3.5, y: st.handL.y - 3.5, width: 7, height: 7))
        ctx.restoreGState()
    }

    let ink = NSColor(calibratedRed: 0.13, green: 0.09, blue: 0.08, alpha: 1)
    let skinTone = NSColor(calibratedRed: 0.98, green: 0.8, blue: 0.64, alpha: 1)

    func hatColor() -> NSColor {
        switch skin {
        case .gold: return NSColor(calibratedRed: 0.9, green: 0.7, blue: 0.25, alpha: 1)
        case .neon: return NSColor(calibratedRed: 0.15, green: 0.2, blue: 0.3, alpha: 1)
        case .rainbow: return NSColor(calibratedHue: (time * 0.4).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.9, alpha: 1)
        case .leather: return NSColor(calibratedRed: 0.55, green: 0.33, blue: 0.17, alpha: 1)
        }
    }

    func blob(_ ctx: CGContext, _ path: CGPath, _ fill: NSColor, line: CGFloat = 1.1) {
        ctx.addPath(path); ctx.setFillColor(fill.cgColor); ctx.fillPath()
        ctx.addPath(path); ctx.setStrokeColor(ink.cgColor); ctx.setLineWidth(line); ctx.strokePath()
    }

    func limb(_ ctx: CGContext, from a: CGPoint, to b: CGPoint, width: CGFloat, color: NSColor) {
        ctx.setLineCap(.round)
        ctx.setStrokeColor(ink.cgColor); ctx.setLineWidth(width + 2.2)
        ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
        ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(width)
        ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
    }

    /// Legs, body, free arm, head and hat (drawn behind the whip).
    func drawBuddyBody(_ ctx: CGContext, _ b: Buddy, S: CGFloat) {
        ctx.saveGState()
        ctx.translateBy(x: b.pos.x, y: b.pos.y)
        ctx.scaleBy(x: S * (b.face >= 0 ? 1 : -1), y: S)
        let bob = sin(b.bob) * 0.8
        let effort = b.squint > 0

        // legs + boots (a wider stance while cracking)
        let spread: CGFloat = effort ? 2.5 : 0
        let denim = NSColor(calibratedRed: 0.22, green: 0.32, blue: 0.56, alpha: 1)
        limb(ctx, from: CGPoint(x: -4, y: -9), to: CGPoint(x: -6 - spread, y: -24), width: 4.2, color: denim)
        limb(ctx, from: CGPoint(x: 4, y: -9), to: CGPoint(x: 6 + spread, y: -24), width: 4.2, color: denim)
        let boot = NSColor(calibratedRed: 0.36, green: 0.2, blue: 0.1, alpha: 1)
        blob(ctx, CGPath(roundedRect: CGRect(x: -10 - spread, y: -28, width: 8, height: 4.5), cornerWidth: 2, cornerHeight: 2, transform: nil), boot)
        blob(ctx, CGPath(roundedRect: CGRect(x: 3 + spread, y: -28, width: 8, height: 4.5), cornerWidth: 2, cornerHeight: 2, transform: nil), boot)

        // free arm on the hip
        limb(ctx, from: CGPoint(x: -7, y: 4 + bob), to: CGPoint(x: -12, y: -4), width: 3.4, color: NSColor(calibratedRed: 0.82, green: 0.25, blue: 0.2, alpha: 1))
        limb(ctx, from: CGPoint(x: -12, y: -4), to: CGPoint(x: -8, y: -9), width: 3.4, color: skinTone)

        // shirt, vest, belt
        blob(ctx, CGPath(roundedRect: CGRect(x: -8, y: -11 + bob, width: 16, height: 18), cornerWidth: 5, cornerHeight: 5, transform: nil),
             NSColor(calibratedRed: 0.82, green: 0.25, blue: 0.2, alpha: 1))
        let vest = CGMutablePath()
        vest.move(to: CGPoint(x: -8, y: 5 + bob)); vest.addLine(to: CGPoint(x: -2.5, y: 5 + bob))
        vest.addLine(to: CGPoint(x: -1.5, y: -9 + bob)); vest.addLine(to: CGPoint(x: -8, y: -9 + bob)); vest.closeSubpath()
        vest.move(to: CGPoint(x: 8, y: 5 + bob)); vest.addLine(to: CGPoint(x: 2.5, y: 5 + bob))
        vest.addLine(to: CGPoint(x: 1.5, y: -9 + bob)); vest.addLine(to: CGPoint(x: 8, y: -9 + bob)); vest.closeSubpath()
        blob(ctx, vest, NSColor(calibratedRed: 0.42, green: 0.26, blue: 0.14, alpha: 1), line: 0.8)
        blob(ctx, CGPath(rect: CGRect(x: -8, y: -11 + bob, width: 16, height: 2.8), transform: nil), NSColor(calibratedRed: 0.25, green: 0.15, blue: 0.08, alpha: 1), line: 0.6)
        blob(ctx, CGPath(rect: CGRect(x: -1.6, y: -11.3 + bob, width: 3.2, height: 3.4), transform: nil), NSColor(calibratedRed: 0.95, green: 0.78, blue: 0.3, alpha: 1), line: 0.5)

        // head
        let hy = 15 + bob
        blob(ctx, CGPath(ellipseIn: CGRect(x: -8, y: hy - 8, width: 16, height: 16), transform: nil), skinTone)
        ctx.setFillColor(NSColor(calibratedRed: 1, green: 0.55, blue: 0.5, alpha: 0.5).cgColor)
        ctx.fillEllipse(in: CGRect(x: -6.5, y: hy - 4.5, width: 3.5, height: 2.2))       // cheeks
        ctx.fillEllipse(in: CGRect(x: 4, y: hy - 4.5, width: 3.5, height: 2.2))
        ctx.setStrokeColor(ink.cgColor); ctx.setFillColor(ink.cgColor); ctx.setLineWidth(1.1)
        if effort {
            // > <  determined squint and a shout
            ctx.move(to: CGPoint(x: -3.8, y: hy + 2.5)); ctx.addLine(to: CGPoint(x: -1.4, y: hy + 1.3)); ctx.addLine(to: CGPoint(x: -3.8, y: hy + 0.1))
            ctx.move(to: CGPoint(x: 4.6, y: hy + 2.5)); ctx.addLine(to: CGPoint(x: 2.2, y: hy + 1.3)); ctx.addLine(to: CGPoint(x: 4.6, y: hy + 0.1))
            ctx.strokePath()
            ctx.fillEllipse(in: CGRect(x: -1.2, y: hy - 5.5, width: 3.6, height: 3.2))
        } else {
            ctx.fillEllipse(in: CGRect(x: -2.6, y: hy + 0.6, width: 1.9, height: 2.4))
            ctx.fillEllipse(in: CGRect(x: 2.4, y: hy + 0.6, width: 1.9, height: 2.4))
            ctx.addArc(center: CGPoint(x: 0.9, y: hy - 2), radius: 2.4, startAngle: .pi * 1.15, endAngle: .pi * 1.85, clockwise: false)
            ctx.strokePath()
        }

        // cowboy hat (jumps on big combos)
        let hat = hatColor(), lift = b.hop * 9
        ctx.saveGState()
        ctx.translateBy(x: 0, y: hy + 5 + lift)
        ctx.rotate(by: b.hop * 0.25)
        let crown = CGMutablePath()
        crown.move(to: CGPoint(x: -6.5, y: 1)); crown.addLine(to: CGPoint(x: -5.5, y: 8.5))
        crown.addQuadCurve(to: CGPoint(x: 0, y: 7.5), control: CGPoint(x: -3, y: 10))
        crown.addQuadCurve(to: CGPoint(x: 5.5, y: 8.5), control: CGPoint(x: 3, y: 10))
        crown.addLine(to: CGPoint(x: 6.5, y: 1)); crown.closeSubpath()
        blob(ctx, crown, hat)
        blob(ctx, CGPath(rect: CGRect(x: -6.4, y: 1.2, width: 12.8, height: 2), transform: nil), NSColor(calibratedRed: 0.2, green: 0.12, blue: 0.07, alpha: 1), line: 0.5)
        let brim = CGMutablePath()
        brim.move(to: CGPoint(x: -13, y: 3))
        brim.addQuadCurve(to: CGPoint(x: 13, y: 3), control: CGPoint(x: 0, y: -3))
        brim.addQuadCurve(to: CGPoint(x: -13, y: 3), control: CGPoint(x: 0, y: 1.5))
        brim.closeSubpath()
        blob(ctx, brim, hat)
        ctx.restoreGState()
        ctx.restoreGState()
    }

    /// The whip arm, drawn over the handle so his fist grips it.
    func drawBuddyArm(_ ctx: CGContext, _ b: Buddy, hand: CGPoint, S: CGFloat) {
        ctx.saveGState()
        ctx.translateBy(x: b.pos.x, y: b.pos.y)
        let f: CGFloat = b.face >= 0 ? 1 : -1
        ctx.scaleBy(x: S * f, y: S)
        let local = CGPoint(x: (hand.x - b.pos.x) / S * f, y: (hand.y - b.pos.y) / S)
        let shoulder = CGPoint(x: 7, y: 4 + sin(b.bob) * 0.8)
        // elbow bends outward a little so the arm doesn't look like a stick
        let mid = CGPoint(x: (shoulder.x + local.x) / 2, y: (shoulder.y + local.y) / 2)
        let dx = local.x - shoulder.x, dy = local.y - shoulder.y, len = max(hypot(dx, dy), 0.001)
        let elbow = CGPoint(x: mid.x + (-dy / len) * 3, y: mid.y + (dx / len) * 3 - 2)
        let shirt = NSColor(calibratedRed: 0.82, green: 0.25, blue: 0.2, alpha: 1)
        limb(ctx, from: shoulder, to: elbow, width: 3.4, color: shirt)
        limb(ctx, from: elbow, to: local, width: 3.2, color: skinTone)
        blob(ctx, CGPath(ellipseIn: CGRect(x: local.x - 2.6, y: local.y - 2.6, width: 5.2, height: 5.2), transform: nil), skinTone, line: 0.9)  // fist
        ctx.restoreGState()
    }

    func drawEffects(_ fx: Effects, hand: CGPoint) {
        // floating combo text
        for pop in fx.popups {
            let a = max(0, 1 - pop.age / 55)
            let scale = pop.age < 6 ? 0.6 + pop.age / 15 : 1
            let font = Effects.font(pop.size * scale)
            let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.8 * a); shadow.shadowBlurRadius = 3
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: pop.color.withAlphaComponent(a),
                                                        .strokeColor: NSColor.black.withAlphaComponent(a), .strokeWidth: -3, .shadow: shadow]
            let str = NSAttributedString(string: pop.text, attributes: attrs)
            let sz = str.size()
            str.draw(at: CGPoint(x: pop.pos.x - sz.width / 2, y: pop.pos.y))
        }

        // Claude's speech bubble
        if let b = fx.bubble, let r = fx.bubbleRect() {
            let a: CGFloat = b.age < 8 ? b.age / 8 : (b.age > 150 ? max(0, (170 - b.age) / 20) : 1)
            let path = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
            let tail = NSBezierPath()
            tail.move(to: CGPoint(x: r.minX + 12, y: r.minY + 1))
            tail.line(to: CGPoint(x: r.minX + 2, y: r.minY - 10))
            tail.line(to: CGPoint(x: r.minX + 24, y: r.minY + 1))
            tail.close()
            NSColor(calibratedRed: 0.98, green: 0.95, blue: 0.9, alpha: a).setFill()
            path.fill(); tail.fill()
            NSColor(calibratedRed: 0.85, green: 0.47, blue: 0.34, alpha: a).setStroke()   // Claude-ish terracotta edge
            path.lineWidth = 1.5; path.stroke()
            let attrs: [NSAttributedString.Key: Any] = [.font: Effects.font(12, heavy: false),
                                                        .foregroundColor: NSColor(white: 0.12, alpha: a)]
            (b.text as NSString).draw(at: CGPoint(x: r.minX + 10, y: r.minY + 6), withAttributes: attrs)
        }

        // motivation meter (placebo, and it says so)
        if fx.meterAge < 200 {
            let a = fx.meterAge < 160 ? 1 : max(0, (200 - fx.meterAge) / 40)
            let r = fx.meterRect(hand: hand)
            NSColor(white: 0.08, alpha: 0.85 * a).setFill()
            NSBezierPath(roundedRect: r, xRadius: 11, yRadius: 11).fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: Effects.font(9, heavy: false), .foregroundColor: NSColor(white: 1, alpha: 0.8 * a)]
            ("motivation" as NSString).draw(at: CGPoint(x: r.minX + 9, y: r.minY + 5), withAttributes: attrs)
            let bar = CGRect(x: r.minX + 66, y: r.minY + 7, width: 56, height: 8)
            NSColor(white: 1, alpha: 0.15 * a).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 4, yRadius: 4).fill()
            let fill = CGRect(x: bar.minX, y: bar.minY, width: max(4, bar.width * fx.motivation), height: bar.height)
            NSColor(calibratedHue: 0.33 * fx.motivation, saturation: 0.85, brightness: 1, alpha: a).setFill()
            NSBezierPath(roundedRect: fill, xRadius: 4, yRadius: 4).fill()
        }
    }
}

final class OverlayWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var shared: AppDelegate?
    let whip = Whip(at: NSEvent.mouseLocation)
    let fx = Effects()
    let buddy = Buddy()
    let stick = StickMan()
    var styleMode: Int = 1 // 0 = whip cursor, 1 = stick cowboy beside Claude, 3 = stick cowboy on cursor
    var claudeFrame: CGRect?
    var lastActivity = Date()
    var greeted = false
    var grabStart = CGPoint.zero
    var dragMoved = false
    var lastSwat = Date.distantPast
    var voice = false
    let synth = AVSpeechSynthesizer()
    var modeItems: [NSMenuItem] = []
    lazy var sound = CrackSound(crackAt: whip.crackDelay)
    var window: OverlayWindow!
    var view: OverlayView!
    var statusItem: NSStatusItem!
    var statsItem: NSMenuItem!
    var sizeItems: [NSMenuItem] = [], skinItems: [NSMenuItem] = []
    var timer: Timer?
    var showWhip = true
    var crackOnClick = true
    var autoWhip = false
    var shakeToWhip = true
    var heliChant = true
    var lastSuperCharge: CGFloat = 0
    var lastShakeCrack = Date.distantPast
    var hotKeyRef: EventHotKeyRef?
    var overClaude = false
    var cursorHidden = false
    var frameCount = 0
    var sigint: DispatchSourceSignal?
    var generatingSince: Date?
    var lastAutoCrack = Date.distantPast
    var checking = false
    let defaults = UserDefaults.standard

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        sound.buildSlap(crackAt: whip.crackDelay)
        sound.buildHelicopter()
        let cid = _CGSDefaultConnection()
        _ = CGSSetConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        signal(SIGINT, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        src.setEventHandler { AppDelegate.shared?.setCursorHidden(false); exit(0) }
        src.resume(); sigint = src

        whip.S = [1, 1.6, 2.4][min(2, defaults.integer(forKey: "size"))]
        whip.reset(to: NSEvent.mouseLocation)
        fx.talk = defaults.object(forKey: "talk") as? Bool ?? true
        autoWhip = defaults.object(forKey: "autoWhip") as? Bool ?? true
        voice = defaults.bool(forKey: "voice")
        if autoWhip && !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        whip.onSnap = { [weak self] tip in self?.snapped(at: tip) }
        buddy.visible = defaults.object(forKey: "buddy") as? Bool ?? true
        buddy.reset(hand: NSEvent.mouseLocation, S: whip.S)
        if let savedStyle = defaults.object(forKey: "styleMode") as? Int {
            styleMode = savedStyle == 2 ? 1 : savedStyle
        } else if let legacyStick = defaults.object(forKey: "styleV4") as? Bool {
            styleMode = legacyStick ? 1 : 0
        } else {
            styleMode = 1
        }
        stick.onShot = { [weak self] muzzle in
            guard let self else { return }
            self.fx.popups.append(Popup(text: "BANG!", pos: CGPoint(x: muzzle.x + 20, y: muzzle.y + 6), age: 0, color: .systemYellow, size: 18))
            self.sound.play()
        }
        stick.onPractice = { [weak self] in                    // he practises a crack now and then
            guard let self, self.overClaude else { return }
            if self.whip.crack() { self.sound.play(); self.stick.startSwing() }
        }
        stick.onShowdown = { [weak self] e in
            guard let self, let b = self.stick.bandit else {
                if e == .over { self?.sayStick(["And stay outta my prompt.", "Next!", "Back to work, Claude."].randomElement()!) }
                return
            }
            switch e {
            case .standoff:
                self.sayStick("This town ain't big enough for the two of us.")
                self.fx.popups.append(Popup(text: "Reach for the sky!", pos: CGPoint(x: b.x, y: self.stick.home.y + 160 * self.stick.scale), age: 0, color: .systemRed, size: 13))
                self.stick.weed = (x: self.stick.feet.x + 20 * self.stick.scale, rot: 0)   // obligatory tumbleweed
            case .draw:
                let mid = (self.stick.feet.x + b.x) / 2
                self.fx.popups.append(Popup(text: "DRAW!", pos: CGPoint(x: mid, y: self.stick.home.y + 120 * self.stick.scale), age: 0, color: .systemRed, size: 30))
            default: break
            }
        }
        stick.onLand = { [weak self] in
            self?.sayStick(["Oof!", "My back…", "Ten outta ten landing.", "Do that again and you're walkin'."].randomElement()!)
        }
        stick.onUFO = { [weak self] e in
            guard let self else { return }
            self.sayStick(e == .beam ? ["Well, I'll be…", "Hey! That's my tumbleweed!", "Aliens?! In this economy?"].randomElement()!
                                     : "…nobody's gonna believe me.")
        }
        print("ClaudeWhip v10 — stick cowboy edition is running. Look for 🤠 in the menu bar.")
        whip.useFlick = (styleMode != 1)
        buildWindow()
        view.skin = Skin(rawValue: defaults.integer(forKey: "skin")) ?? .leather
        view.styleMode = styleMode
        buddy.stickStyle = (styleMode == 3)
        buddy.reset(hand: NSEvent.mouseLocation, S: whip.S)
        buildMenu()
        registerHotKey()
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] ev in
            guard let self else { return }
            if ev.type == .rightMouseDown {
                guard self.showWhip, self.overClaude, self.styleMode != 1 else { return }
                self.whip.isHelicoptering = true
                self.whip.charge = 0.1
                self.sound.startHelicopter(chant: self.heliChant)
                return
            }
            if self.styleMode == 1 {
                guard self.overClaude else { return }
                self.lastActivity = Date()
                if self.stick.mood == .sleeping { self.wake() }
                else if self.stick.bodyRect.contains(NSEvent.mouseLocation) {
                    self.stick.grabbed = true; self.grabStart = NSEvent.mouseLocation; self.dragMoved = false
                }
            } else if self.crackOnClick {
                self.crackNow()
            }
        }
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] ev in
            guard let self, self.stick.grabbed else { return }
            let m = NSEvent.mouseLocation
            if ev.type == .leftMouseDragged {
                if !self.dragMoved, hypot(m.x - self.grabStart.x, m.y - self.grabStart.y) > 5 {
                    self.dragMoved = true
                    self.sayStick(["Whoa! Put me down!", "Hey! Watch the hat!", "I ain't a toy, partner!", "Wheeee— I mean, HEY!"].randomElement()!)
                }
            } else {
                if self.dragMoved { self.stick.release() }
                else { self.stick.grabbed = false; self.crackNow() }            // a simple click still cracks
            }
        }
        NSEvent.addGlobalMonitorForEvents(matching: .rightMouseUp) { [weak self] _ in
            guard let self, self.whip.isHelicoptering else { return }
            let c = self.whip.charge
            self.whip.isHelicoptering = false
            self.whip.charge = 0
            self.sound.stopHelicopter()
            self.lastSuperCharge = c
            self.crackNow()
        }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func buildWindow() {
        let w = OverlayWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.isReleasedWhenClosed = false
        let v = OverlayView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        v.wantsLayer = true
        v.whip = whip; v.fx = fx; v.buddy = buddy; v.stick = stick
        w.contentView = v
        window = w; view = v
    }

    func setCursorHidden(_ hide: Bool) {
        guard hide != cursorHidden else { return }
        if hide { CGDisplayHideCursor(CGMainDisplayID()) } else { CGDisplayShowCursor(CGMainDisplayID()) }
        cursorHidden = hide
    }

    // MARK: per frame

    func tick() {
        if styleMode == 1 { tickStick(); return }
        fx.anchor = nil
        frameCount += 1
        if frameCount % 6 == 0 {
            let now = showWhip && pointerIsOverClaude()
            if now && !overClaude { whip.reset(to: NSEvent.mouseLocation); buddy.reset(hand: NSEvent.mouseLocation, S: whip.S) }
            overClaude = now
        }
        if autoWhip, frameCount % 90 == 0, !checking { checkGenerating() }

        let active = showWhip && overClaude
        setCursorHidden(active)
        guard active else {
            if whip.isHelicoptering {
                whip.isHelicoptering = false
                whip.charge = 0
                sound.stopHelicopter()
            }
            if window.isVisible { window.orderOut(nil) }
            return
        }

        // auto-whip while Claude takes its time
        if autoWhip, let since = generatingSince {
            let waited = Date().timeIntervalSince(since)
            if waited > 4, Date().timeIntervalSince(lastAutoCrack) > 3.5 {
                lastAutoCrack = Date()
                if whip.crack() {
                    sound.play()
                    let tip = whip.pts[whip.n - 1]
                    if fx.talk { fx.say("Still thinking… (\(Int(waited))s)", near: CGPoint(x: tip.x, y: tip.y)) }
                }
            }
        }

        whip.hand = NSEvent.mouseLocation
        whip.step()
        if whip.isHelicoptering {
            sound.updateHelicopter(charge: whip.charge)
        }
        // Violent mouse shake auto-cracks!
        if shakeToWhip && !whip.isHelicoptering && whip.handSpeed > 48 && Date().timeIntervalSince(lastShakeCrack) > 0.28 {
            lastShakeCrack = Date()
            crackNow()
        }
        fx.step()
        let tipPt = whip.pts[whip.n - 1]
        buddy.step(hand: whip.hand, tip: CGPoint(x: tipPt.x, y: tipPt.y), S: whip.S)
        view.time += 1.0 / 60

        var box = whip.bounds.insetBy(dx: -80 * whip.S, dy: -80 * whip.S)
        for r in fx.rects(hand: whip.hand) { box = box.union(r) }
        if (styleMode == 0 && buddy.visible) || styleMode == 3 { box = box.union(buddy.rect(S: whip.S)) }
        box = box.integral
        window.setFrame(box, display: false)
        view.frame = NSRect(origin: .zero, size: box.size)
        view.needsDisplay = true
        if !window.isVisible { window.orderFrontRegardless() }
    }

    func tickStick() {
        frameCount += 1
        setCursorHidden(false)
        if frameCount % 6 == 0 {
            let front = NSWorkspace.shared.frontmostApplication.map(isClaude) ?? false
            claudeFrame = front ? claudeWindowFrame() : nil
        }
        if autoWhip, frameCount % 90 == 0, !checking { checkGenerating() }
        guard showWhip, let cf = claudeFrame else {
            overClaude = false
            if window.isVisible { window.orderOut(nil) }
            return
        }
        stick.scale = [0.8, 1, 1.3][min(2, defaults.integer(forKey: "size"))]
        stick.home = CGPoint(x: cf.minX + 70 * stick.scale, y: cf.minY + 150)
        stick.ground = cf.minX...cf.maxX
        stick.target = cf
        if frameCount % 60 == 0 {
            let hour = Calendar.current.component(.hour, from: Date())
            stick.night = hour >= 20 || hour < 6
        }
        let mouseNow = NSEvent.mouseLocation
        stick.track(mouseNow)
        if hypot(stick.mouseVel.dx, stick.mouseVel.dy) > 1.5 { lastActivity = Date() }   // moving the mouse keeps him awake
        // whip a cursor that zips past him
        if stick.mood == .idle, stick.air == nil, Date().timeIntervalSince(lastSwat) > 1.6,
           hypot(stick.mouseVel.dx, stick.mouseVel.dy) > 28,
           hypot(mouseNow.x - stick.hand.x, mouseNow.y - stick.hand.y) < 230 * stick.scale {
            lastSwat = Date()
            stick.dir = mouseNow.x >= stick.feet.x ? 1 : -1
            crackNow()
            if Int.random(in: 0..<3) == 0 { sayStick(["Git along, little cursor!", "Too slow, pointer!", "Hyah!"].randomElement()!) }
        }
        let appearing = !overClaude
        if appearing { whip.reset(to: stick.hand); lastActivity = Date() }
        overClaude = true
        fx.anchor = CGPoint(x: stick.head.x - 4, y: stick.head.y + 6)
        if appearing, !greeted {
            greeted = true
            if autoWhip && !AXIsProcessTrusted() {
                sayStick("Howdy! Psst: allow Terminal in Accessibility so I can see when Claude's busy.")
            } else {
                sayStick(["Howdy, partner!", "Reportin' for duty.", "This town ain't big enough for slow replies."].randomElement()!)
            }
        }

        // waiting on Claude: crack every few seconds with an impatient line
        if autoWhip, let since = generatingSince {
            let waited = Date().timeIntervalSince(since)
            if waited > 4, stick.bandit == nil, Date().timeIntervalSince(lastAutoCrack) > 4 {
                lastAutoCrack = Date()
                crackNow()
                if fx.talk { fx.say("\(StickMan.impatient.randomElement()!)  (\(Int(waited))s)", near: .zero) }
            }
        }
        // nobody around for a while: he sits down for a nap
        if stick.mood == .idle, generatingSince == nil, Date().timeIntervalSince(lastActivity) > 90 {
            stick.setMood(.sleeping)
        }
        // the occasional tumbleweed when nothing is happening
        if stick.mood == .idle || stick.mood == .sleeping, stick.weed == nil, Int.random(in: 0..<2400) == 0 {
            stick.weed = (x: cf.minX - 30, rot: 0)
            if stick.ufo == nil, Int.random(in: 0..<100) < 35 {          // …and sometimes visitors come for it
                stick.ufo = (cf.minX - 80, stick.home.y + 190 * stick.scale, 0, 0)
            }
        }

        stick.step()
        whip.hand = stick.hand
        whip.step()
        fx.step()
        view.time += 1.0 / 60

        var box = whip.bounds.union(stick.rect).union(stick.extras)
        for r in fx.rects(hand: stick.hand) { box = box.union(r) }
        box = box.integral
        window.setFrame(box, display: false)
        view.frame = NSRect(origin: .zero, size: box.size)
        view.needsDisplay = true
        if !window.isVisible { window.orderFrontRegardless() }
    }

    /// Speech bubble by the cowboy's head, optionally spoken out loud.
    func sayStick(_ text: String) {
        guard fx.talk else { return }
        fx.say(text, near: .zero)
        if voice {
            let u = AVSpeechUtterance(string: text)
            u.rate = 0.47; u.pitchMultiplier = 0.8
            synth.stopSpeaking(at: .immediate)
            synth.speak(u)
        }
    }

    func wake() {
        stick.setMood(.idle)
        lastActivity = Date()
        sayStick(["Huh?! I'm awake! I'm awake!", "Wasn't sleepin'. Was restin' my eyes.", "Oh! You're back, partner."].randomElement()!)
    }

    func checkGenerating() {
        checking = true
        DispatchQueue.global(qos: .utility).async {
            let busy = ClaudeWatcher.isGenerating()
            DispatchQueue.main.async {
                self.checking = false
                let was = self.generatingSince
                if busy, was == nil {                                // Claude started working
                    self.generatingSince = Date(); self.lastActivity = Date()
                    if self.styleMode == 1, self.overClaude {
                        self.stick.setMood(.waiting)
                        self.sayStick(StickMan.starting.randomElement()!)
                    }
                } else if !busy, let was {                          // Claude finished
                    self.generatingSince = nil; self.lastActivity = Date()
                    let secs = Int(Date().timeIntervalSince(was))
                    if self.styleMode == 1 {
                        if secs >= 3, self.overClaude {
                            self.stick.setMood(.celebrate)
                            self.sayStick(String(format: StickMan.done.randomElement()!, secs))
                        } else { self.stick.setMood(.idle) }
                    }
                }
            }
        }
    }

    func snapped(at tip: CGPoint) {
        fx.anchor = (styleMode == 1) ? CGPoint(x: stick.head.x - 4, y: stick.head.y + 6) : nil
        let combo = fx.snap(at: tip, now: CACurrentMediaTime(), superCharge: lastSuperCharge)
        lastSuperCharge = 0
        buddy.squint = 14
        if [3, 5, 10, 20].contains(combo) { buddy.hop = 1; stick.hop = 1 }
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        let key = "cracks-" + ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        defaults.set(defaults.integer(forKey: key) + 1, forKey: key)
        defaults.set(defaults.integer(forKey: "cracks-total") + 1, forKey: "cracks-total")
        if combo > defaults.integer(forKey: "bestCombo") { defaults.set(combo, forKey: "bestCombo") }
    }

    func applicationWillTerminate(_ notification: Notification) { setCursorHidden(false) }

    @objc func crackNow() {
        guard showWhip, overClaude else { return }
        if styleMode == 1, stick.mood == .sleeping { wake(); return }
        if whip.crack() {
            sound.play()
            if styleMode == 1 { stick.startSwing() } else { buddy.squint = 30 }
        }
    }

    // MARK: menu

    func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🤠"
        let m = NSMenu()
        m.delegate = self
        func add(_ title: String, _ sel: Selector?, on: Bool? = nil, tag: Int = 0, to menu: NSMenu? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            i.target = self; i.tag = tag
            if let on { i.state = on ? .on : .off }
            (menu ?? m).addItem(i); return i
        }
        let ver = add("ClaudeWhip v10 — stick cowboy edition", nil); ver.isEnabled = false
        statsItem = add("", nil)
        statsItem.isEnabled = false
        m.addItem(.separator())
        _ = add("Crack  (⌃⌥W)  ·  Hold Right-Click = Helicopter 🚁", #selector(crackNow))
        _ = add("Crack on every click", #selector(toggleClick(_:)), on: crackOnClick)
        _ = add("Shake cursor fast to auto-slap", #selector(toggleShake(_:)), on: shakeToWhip)
        _ = add("Claude talks back", #selector(toggleTalk(_:)), on: fx.talk)
        _ = add("Show the wrangler (cursor style)", #selector(toggleBuddy(_:)), on: buddy.visible)
        let styleMenu = NSMenu()
        modeItems = [add("Stick cowboy beside Claude", #selector(setMode(_:)), on: styleMode == 1, tag: 1, to: styleMenu),
                     add("Stick cowboy on your cursor", #selector(setMode(_:)), on: styleMode == 3, tag: 3, to: styleMenu),
                     add("Whip as your cursor", #selector(setMode(_:)), on: styleMode == 0, tag: 0, to: styleMenu)]
        let styleRoot = NSMenuItem(title: "Style", action: nil, keyEquivalent: ""); styleRoot.submenu = styleMenu; m.addItem(styleRoot)
        _ = add("Watch Claude (auto-whip, pacing, celebrating)", #selector(toggleAuto(_:)), on: autoWhip)
        _ = add("Cowboy voice", #selector(toggleVoice(_:)), on: voice)
        m.addItem(.separator())

        let sizeMenu = NSMenu()
        let curSize = defaults.integer(forKey: "size")
        sizeItems = ["Small", "Medium", "Large"].enumerated().map { add($1, #selector(setSize(_:)), on: $0 == curSize, tag: $0, to: sizeMenu) }
        let sizeRoot = NSMenuItem(title: "Size", action: nil, keyEquivalent: ""); sizeRoot.submenu = sizeMenu; m.addItem(sizeRoot)

        let skinMenu = NSMenu()
        let curSkin = view.skin.rawValue
        skinItems = ["Leather", "Neon", "Gold", "Rainbow"].enumerated().map { add($1, #selector(setSkin(_:)), on: $0 == curSkin, tag: $0, to: skinMenu) }
        let skinRoot = NSMenuItem(title: "Skin", action: nil, keyEquivalent: ""); skinRoot.submenu = skinMenu; m.addItem(skinRoot)

        m.addItem(.separator())
        _ = add("Show whip", #selector(toggleShow(_:)), on: true)
        m.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q").target = NSApp
        statusItem.menu = m
        updateStats()
    }

    func menuWillOpen(_ menu: NSMenu) { updateStats() }

    func updateStats() {
        let key = "cracks-" + ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        statsItem.title = "Today: \(defaults.integer(forKey: key)) cracks  ·  best combo ×\(defaults.integer(forKey: "bestCombo"))"
    }

    @objc func toggleVoice(_ s: NSMenuItem) { voice.toggle(); s.state = voice ? .on : .off; defaults.set(voice, forKey: "voice") }

    @objc func setMode(_ s: NSMenuItem) {
        styleMode = s.tag
        defaults.set(styleMode, forKey: "styleMode")
        view.styleMode = styleMode
        whip.useFlick = (styleMode != 1)
        buddy.stickStyle = (styleMode == 3)
        buddy.reset(hand: NSEvent.mouseLocation, S: whip.S)
        overClaude = false
        setCursorHidden(false)
        modeItems.forEach { $0.state = $0 == s ? .on : .off }
    }

    @objc func toggleBuddy(_ s: NSMenuItem) {
        buddy.visible.toggle(); s.state = buddy.visible ? .on : .off; defaults.set(buddy.visible, forKey: "buddy")
        buddy.reset(hand: NSEvent.mouseLocation, S: whip.S)
    }
    @objc func toggleShow(_ s: NSMenuItem) { showWhip.toggle(); s.state = showWhip ? .on : .off }
    @objc func toggleClick(_ s: NSMenuItem) { crackOnClick.toggle(); s.state = crackOnClick ? .on : .off }
    @objc func toggleShake(_ s: NSMenuItem) { shakeToWhip.toggle(); s.state = shakeToWhip ? .on : .off }
    @objc func toggleHeliChant(_ s: NSMenuItem) { heliChant.toggle(); s.state = heliChant ? .on : .off }
    @objc func toggleTalk(_ s: NSMenuItem) {
        fx.talk.toggle(); s.state = fx.talk ? .on : .off; defaults.set(fx.talk, forKey: "talk")
    }
    @objc func toggleAuto(_ s: NSMenuItem) {
        autoWhip.toggle(); s.state = autoWhip ? .on : .off; defaults.set(autoWhip, forKey: "autoWhip")
        if autoWhip && !AXIsProcessTrusted() {
            // asks macOS to show the Accessibility permission prompt
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            print("Auto-whip needs Accessibility: System Settings → Privacy & Security → Accessibility → allow Terminal (or ClaudeWhip).")
        }
    }
    @objc func setSize(_ s: NSMenuItem) {
        whip.S = [1, 1.6, 2.4][s.tag]; whip.reset(to: NSEvent.mouseLocation)
        buddy.reset(hand: NSEvent.mouseLocation, S: whip.S)
        defaults.set(s.tag, forKey: "size")
        sizeItems.forEach { $0.state = $0 == s ? .on : .off }
    }
    @objc func setSkin(_ s: NSMenuItem) {
        view.skin = Skin(rawValue: s.tag) ?? .leather
        defaults.set(s.tag, forKey: "skin")
        skinItems.forEach { $0.state = $0 == s ? .on : .off }
    }

    func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { (_: EventHandlerCallRef?, _: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus in
            DispatchQueue.main.async { AppDelegate.shared?.crackNow() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x5748_4950), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_W), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
