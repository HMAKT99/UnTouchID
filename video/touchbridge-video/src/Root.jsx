import { Composition } from "remotion";
import { TouchBridgeVideo } from "./TouchBridgeVideo.jsx";

export const RemotionRoot = () => {
  return (
    <Composition
      id="TouchBridge"
      component={TouchBridgeVideo}
      durationInFrames={900} // 30 seconds at 30fps
      fps={30}
      width={1920}
      height={1080}
    />
  );
};
