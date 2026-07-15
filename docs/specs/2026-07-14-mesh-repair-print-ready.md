# Mesh Repair for Print-Ready Export — 设计文档

- 日期: 2026-07-14
- 状态: 设计 / 可行性(未实现)
- 目标项目: Modelr (ZimengXiong/Modelr) — 本地 image→3D 生成 macOS 应用
- 范围: **仅自动修复**。省料/抽壳优化是独立特性,不在本文档内。

---

## 1. 背景与问题

Modelr 生成的网格导入切片器(Cura / PrusaSlicer)会出现
"not watertight / non-manifold" 类警告,虽然切片器能自动修复,但希望**工具端直接产出可打印文件**,免去这一步。

### 1.1 现状诊断(基于源码)

- 形状网格来自 **SDF + Marching Cubes**(`Packages/Hy3DMLX/.../Pipeline.swift`、`MarchingCubes.swift`),
  MC 输出本应是水密流形。
- STL 导出(`Sources/Core/MeshExporter.swift:144` `encodeSTL`)按**索引顶点**写出,
  同一索引总是发出**逐字节一致**的坐标,所以未 UV 劈裂的 shape `.mesh` 在切片器里应能按精确坐标重新焊合。

因此真正触发切片器报错的来源较窄,集中在:

1. **导出的是 paint 网格**:`.tmesh` 经 xatlas UV 展开后**沿接缝劈裂顶点**
   (`Packages/HunyuanPaintMLX/.../Pipeline.swift`),几何上闭合但顶点分裂 → 接缝处判为非水密/非流形。
2. **QEM 简化产物**(`Sources/Core/MeshDecimator.swift`):偶发退化面、近重复面、少量非流形边
   (该模块已拒绝法线翻转与非流形折叠,但边界情形仍可能残留)。
3. **MC 噪点 / 薄壳**:低密度区域的悬浮小碎壳、纸片状特征。

### 1.2 目标(成功标准)

- 打印导出(STL)默认输出**水密、2-manifold、法线朝外**的网格,切片器零警告零手动修复。
- **确定性**:相同输入 → 逐字节相同输出(延续 `MeshDecimator` 的工程约束)。
- **可 headless 测试**:纯 Foundation,无 GPU / 无网络,进 `ModelrTests`。
- **零新依赖**(路线 A);不引入 C++ 库。
- **永不硬失败**:修不干净则告警 + 尽力导出(延续 decimation 的"回退原网格"哲学)。

### 1.3 非目标

- 省料 / 抽壳(独立特性)。
- 自相交(self-intersection)消除 —— MC/SDF 网格极少出现;若需要,由路线 B 或未来 vendored 库处理。记为已知限制。
- 最小壁厚检测 / 增厚。

---

## 2. 架构

### 2.1 新模块 `MeshRepair`

- 位置: `Sources/Core/MeshRepair.swift`
- 形态: 纯 Foundation `enum`,无 AppKit/SceneKit/MLX 依赖 —— 与 `MeshExporter`、`MeshDecimator` 同风格,可离线单测、可在主线程外运行。
- 数据表示: 复用索引网格 `verts: [Float]`(3×n)、`indices: [UInt32]`(3×m),
  与 `MeshExporter.MeshData` 一致,便于直接接入导出路径。

```
enum MeshRepair {
    struct Mesh { var verts: [Float]; var indices: [UInt32] }   // normals 修复后重算

    struct Report {                 // 可用于 UI 提示与测试断言
        var welded: Int             // 焊合掉的重复顶点数
        var degenerateRemoved: Int
        var holesFilled: Int
        var nonManifoldFixed: Int
        var componentsDropped: Int
        var flippedToOutward: Bool
        var fullyWatertight: Bool    // 修复后是否达成水密流形
    }

    static func makePrintable(_ mesh: Mesh) -> (Mesh, Report)   // 路线 A

    // 校验(测试 oracle + 导出门禁)
    static func validate(_ mesh: Mesh) -> Validation            // isWatertight / isManifold / isOriented
}
```

### 2.2 接入点

- **格式路由**:`MeshExporter.export` 的 `.stl` 分支在 `encodeSTL` 之前调用 `MeshRepair.makePrintable`。
- **几何来源**:打印导出优先取**未 UV 劈裂的 shape 几何**,而非 paint 的 UV 网格
  —— 复用 `ProjectStore.shapeMeshURL(for:)`。STL 无纹理槽,打印只需几何,此举天然回避接缝分裂问题。
- **暴露方式(两档,可分期)**:
  - 最小版: STL 导出内部默认开启,用户无感。
  - 完整版: 导出面板加"repair for printing"开关 + "force watertight(路线 B)"开关;
    并复用 reducer 做成**可取消 / 带进度**的独立阶段(仿 paint 的 `unwrapPaintMesh` 阶段,见 `Sources/AppRuntime.swift:246`)。

### 2.3 复用现有代码

- `MeshDecimator`(`Sources/Core/MeshDecimator.swift`)已有 `edgeKey`/`unpack`、`vFaces` 邻接、
  `neighbors()`、`isBoundaryVertex()` —— 拓扑修复(补洞、非流形检测、朝向、连通分量)直接复用其结构。
- 路线 B 复用 `MarchingCubes`(`Packages/Hy3DMLX/.../MarchingCubes.swift`)与 SDF 网格。

---

## 3. 修复流水线(路线 A,默认)

顺序重要,每步在上一步的干净输出上进行:

1. **焊合重合顶点(weld)**
   - 坐标量化到 ε 网格(相对包围盒对角线,如 1e-5),空间哈希聚合重合点,重映射 `indices`,去重顶点表。
   - 修 UV seam 劈裂、MC 边重复。
   - 确定性: 以量化格点为键、按排序顺序分配新索引。

2. **删退化面(degenerate)**
   - 零面积面(索引重复,或三顶点近共线 area<ε)剔除。
   - 精确重复面(排序后三元组相同)去重。

3. **压缩(compact)**
   - 移除焊合/删面后无引用的顶点,重排索引。

4. **拓扑修复(topology)**
   - 构建 edge→faces 邻接(复用 `edgeKey`)。
   - **边界边**(count==1): 追踪边界环;小环用扇形 / 最小面积三角化填补;
     超过阈值的大洞标记到 `Report`(交由路线 B 或告警)。
   - **非流形边**(count>2): 删除 / 劈裂多余面,恢复每边 ≤2 面。

5. **统一朝向(orientation)**
   - 沿共享边泛洪(BFS),逐壳统一三角形绕序。
   - 计算整体**有符号体积**(Σ 四面体带符号体积);为负则全体翻转 → 法线朝外。

6. **去小碎片(components)**
   - 面邻接做连通分量标记;丢弃面数 / 体积低于阈值的悬浮壳(清 MC 噪点)。

7. **重算法线**
   - 面积加权顶点法线(与 `ShapeMeshWriter` 一致,见 `Sources/ShapeEngine.swift:147`),供后续导出。

---

## 4. 路线 B(可选:保证水密)

用于路线 A 修不干净(大洞、复杂非流形、自相交)时的兜底,或用户显式勾选 "force watertight"。

- **原理**: 把网格重新表达为 SDF / 占据场,再跑 Marching Cubes 重抽等值面 → **保证 2-manifold 水密**。
- **自产形状**: Modelr 在 MC 之前本就算出 SDF 网格,可保留 / 重算后直接重抽,近乎免费。
- **任意 / 导入网格**: 用**广义缠绕数(Generalized Winding Number, Jacobson 2013)** 对"三角形汤"算内外场,体素化后抽面。
- **代价**: 轻微丢细节、增内存;较重,opt-in。
- **复用**: `MarchingCubes.extract`。

---

## 5. 错误处理

- `makePrintable` 永不 throw:任何一步失败 / 修不干净,都保留当前尽力结果并在 `Report` 标注。
- 导出层:若 `Report.fullyWatertight == false` 且未开路线 B,导出仍继续,但给出**非阻塞告警**("已尽力修复,仍可能有 N 处问题;可开启 force watertight")。
- 与 decimation 相同哲学:宁可产出"更好但不完美",不阻断用户导出。

---

## 6. 测试

- 位置: `Tests/MeshRepairTests.swift`(headless,无 GPU/网络,同 `MeshDecimatorTests`/`MeshExporterTests`)。
- 用例(构造带已知缺陷的最小网格 → 断言修复结果):
  1. UV 劈裂(重合顶点)→ 焊合后顶点数下降、水密。
  2. 单面缺失(洞)→ 补洞后无边界边。
  3. 非流形边(3 面共享)→ 修复后每边 ≤2 面。
  4. 翻转面 / 整体内向 → 统一朝向、有符号体积为正。
  5. 悬浮小碎壳 → 被丢弃。
  6. 退化 / 重复三角形 → 被剔除。
  7. 已经干净的网格 → 幂等(输出等价、`fullyWatertight`)。
  8. 确定性: 同输入两次运行输出逐字节相同。
- `validate()` 既作断言 oracle,也可作导出前门禁。

---

## 7. 分期建议

- **P1(最小可用)**: `MeshRepair.makePrintable` 路线 A 第 1–3、5、7 步 + STL 导出默认接入 + 打印优先 shape 几何 + 单测。
  —— 已能消除绝大多数(UV 劈裂 / 退化 / 朝向)报错。
- **P2**: 补洞、非流形边、去碎片(第 4、6 步)+ `Report` UI 告警。
- **P3(可选)**: 路线 B "force watertight" + 导出面板开关 + reducer 可取消阶段。

---

## 8. 已知限制

- 路线 A 不处理自相交(需路线 B / vendored 库)。
- 路线 B 重网格会牺牲少量几何保真度换取水密保证。
- 大洞填补是启发式(扇形/最小面积),复杂凹洞可能需要路线 B。
