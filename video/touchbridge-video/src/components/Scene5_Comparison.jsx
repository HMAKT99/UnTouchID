import { AbsoluteFill, useCurrentFrame, interpolate, spring, useVideoConfig } from "remotion";

export const Scene5_Comparison = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  const titleOpacity = interpolate(frame, [0, 20], [0, 1], { extrapolateRight: "clamp" });

  const rows = [
    { label: "Price", tb: "Free", mk: "$199", aw: "$249+", delay: 20 },
    { label: "sudo", tb: "✅", mk: "✅", aw: "❌", delay: 35 },
    { label: "Wireless", tb: "✅ BLE", mk: "❌ Wired", aw: "✅", delay: 50 },
    { label: "Android", tb: "✅", mk: "❌", aw: "❌", delay: 65 },
    { label: "Open source", tb: "✅", mk: "❌", aw: "❌", delay: 80 },
    { label: "Auto-lock", tb: "✅", mk: "❌", aw: "❌", delay: 95 },
  ];

  const headerOpacity = interpolate(frame, [5, 20], [0, 1], { extrapolateRight: "clamp" });

  return (
    <AbsoluteFill
      style={{
        backgroundColor: "#0a0a1a",
        justifyContent: "center",
        alignItems: "center",
        fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Display', sans-serif",
      }}
    >
      <div style={{ fontSize: 42, fontWeight: 700, color: "#fff", opacity: titleOpacity, marginBottom: 40 }}>
        vs. Alternatives
      </div>

      <div style={{ width: 900 }}>
        {/* Header */}
        <div
          style={{
            display: "flex",
            opacity: headerOpacity,
            padding: "12px 0",
            borderBottom: "2px solid #333",
            marginBottom: 8,
          }}
        >
          <div style={{ flex: 1.5, fontSize: 16, color: "#666" }}></div>
          <div style={{ flex: 1, fontSize: 18, fontWeight: 700, color: "#30d158", textAlign: "center" }}>
            TouchBridge
          </div>
          <div style={{ flex: 1, fontSize: 16, color: "#888", textAlign: "center" }}>Magic Keyboard</div>
          <div style={{ flex: 1, fontSize: 16, color: "#888", textAlign: "center" }}>Apple Watch</div>
        </div>

        {/* Rows */}
        {rows.map((row, i) => {
          const rowOpacity = interpolate(frame, [row.delay, row.delay + 12], [0, 1], {
            extrapolateRight: "clamp",
          });
          const rowX = spring({
            frame: Math.max(0, frame - row.delay),
            fps,
            from: 20,
            to: 0,
            config: { damping: 12 },
          });

          return (
            <div
              key={i}
              style={{
                display: "flex",
                alignItems: "center",
                padding: "14px 0",
                borderBottom: "1px solid #1a1a2e",
                opacity: rowOpacity,
                transform: `translateX(${rowX}px)`,
              }}
            >
              <div style={{ flex: 1.5, fontSize: 20, color: "#ccc", fontWeight: 500 }}>{row.label}</div>
              <div
                style={{
                  flex: 1,
                  fontSize: 20,
                  fontWeight: 700,
                  color: row.tb.includes("Free") || row.tb.includes("✅") ? "#30d158" : "#fff",
                  textAlign: "center",
                }}
              >
                {row.tb}
              </div>
              <div style={{ flex: 1, fontSize: 18, color: "#888", textAlign: "center" }}>{row.mk}</div>
              <div style={{ flex: 1, fontSize: 18, color: "#888", textAlign: "center" }}>{row.aw}</div>
            </div>
          );
        })}
      </div>
    </AbsoluteFill>
  );
};
