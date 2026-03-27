import { AbsoluteFill, Sequence, useCurrentFrame, interpolate, spring, useVideoConfig } from "remotion";
import { Scene1_Problem } from "./components/Scene1_Problem.jsx";
import { Scene2_Solution } from "./components/Scene2_Solution.jsx";
import { Scene3_HowItWorks } from "./components/Scene3_HowItWorks.jsx";
import { Scene4_Devices } from "./components/Scene4_Devices.jsx";
import { Scene5_Comparison } from "./components/Scene5_Comparison.jsx";
import { Scene6_CTA } from "./components/Scene6_CTA.jsx";

export const TouchBridgeVideo = () => {
  return (
    <AbsoluteFill style={{ backgroundColor: "#0a0a1a" }}>
      {/* Scene 1: The Problem (0-5s) */}
      <Sequence from={0} durationInFrames={150}>
        <Scene1_Problem />
      </Sequence>

      {/* Scene 2: The Solution (5-10s) */}
      <Sequence from={150} durationInFrames={150}>
        <Scene2_Solution />
      </Sequence>

      {/* Scene 3: How It Works (10-17s) */}
      <Sequence from={300} durationInFrames={210}>
        <Scene3_HowItWorks />
      </Sequence>

      {/* Scene 4: Every Device (17-22s) */}
      <Sequence from={510} durationInFrames={150}>
        <Scene4_Devices />
      </Sequence>

      {/* Scene 5: Comparison (22-27s) */}
      <Sequence from={660} durationInFrames={150}>
        <Scene5_Comparison />
      </Sequence>

      {/* Scene 6: CTA (27-30s) */}
      <Sequence from={810} durationInFrames={90}>
        <Scene6_CTA />
      </Sequence>
    </AbsoluteFill>
  );
};
