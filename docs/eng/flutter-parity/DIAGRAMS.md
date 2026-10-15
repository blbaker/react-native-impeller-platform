# Diagrams: Flutter-parity rendering engine

Rendered by GitHub (Mermaid). The PR descriptions embed the first two. Sources for every box are in SPEC.md.

## 1. Target thread model (Flutter's platform / UI / raster / IO, the RN way)

```mermaid
flowchart LR
  subgraph JS["JS thread: Hermes, React (Flutter's UI thread)"]
    R["React render"] --> C["Fabric commit<br/>immutable ShadowTree revision"]
  end
  subgraph PL["Platform / main thread"]
    EV["OS events + input"]
    MT["Mount transaction<br/>into SceneGraph"]
    FS["FrameScheduler<br/>per-OS vsync"]
    AN["NativeAnimated tick<br/>LayoutAnimation tick"]
    REC["RECORD: tree walk<br/>into ImpellerDisplayList"]
  end
  subgraph RA["Raster thread"]
    DR["Draw FrameItem<br/>on the Impeller surface"] --> PS["Present<br/>(discard if stale size)"]
  end
  subgraph IO["IO pool"]
    DE["Fetch + decode<br/>+ downscale to box"] --> UP["Texture upload<br/>(resource context)"]
  end
  C -- "MountingTransaction" --> MT
  FS --> AN --> REC
  MT --> REC
  EV --> FS
  REC -- "Pipeline depth 2<br/>(FrameItem)" --> DR
  UP -- "ready textures" --> DR
```

## 2. Backend per OS (what Flutter ships, so what we ship)

```mermaid
flowchart TB
  subgraph APPLE["macOS / iOS"]
    MTL["Impeller Metal<br/>4x MSAA drawable, no supersample"]
  end
  subgraph ANDROID["Android"]
    VK["Impeller Vulkan"] -- "known-bad driver, API < 29,<br/>no Vulkan 1.1" --> AGL["Impeller GLES"]
  end
  subgraph WINDOWS["Windows"]
    WGL["Impeller GLES<br/>+ supersample AA"] --> ANGLE["ANGLE on D3D11"]
  end
  subgraph LINUX["Linux"]
    LGL["Impeller GLES<br/>+ supersample AA"] --> EGL["EGL / Mesa"]
  end
```

## 3. How every change lands

```mermaid
flowchart LR
  P["Pass FP-NN<br/>(one agent session)"] --> NG["New gate<br/>fails on pre-pass code"]
  NG --> MU["Mutants<br/>gate kills each one"]
  MU --> K["16 core gates<br/>stay green"]
  K --> CM["Commit: code + gate + evidence<br/>+ reviewer-grade body"]
  CM --> MJ["Merge job: fresh build,<br/>gates on lane + main"]
  MJ --> PR["PR into main<br/>with docs + evidence"]
```
