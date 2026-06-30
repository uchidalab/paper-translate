# CLIP-Adapter: Better Vision-Language Models with Feature Adapters まとめ

## 概要
大規模視覚言語対比事前学習モデル CLIP を、テキスト側からの prompt tuning に頼らず、軽量な特徴アダプタで fine-tuning する手法 CLIP-Adapter を提案している。CLIP 本体は凍結し、最終層後にボトルネック型アダプタを追加して、残差接続により元の zero-shot 特徴と適応後の特徴を混合することで、few-shot 画像分類において CoOp を含む既存手法を精度・効率の両面で上回ることを示した。

## 背景
CLIP [50] は大規模画像テキスト対の対比学習により open-vocabulary な zero-shot 転移を実現したが、下流タスクでは人手による hard prompt の設計（prompt engineering）が必要であるという問題がある。Context Optimization (CoOp) [75] は few-shot 訓練例から連続的な soft prompt を学習する prompt tuning 手法を提案したが、テキスト側のアプローチに限定される。一方、CLIP 全体を fine-tuning するナイーブなアプローチは、パラメータ数が膨大でかつ few-shot 設定では訓練データが不足するため過学習しやすく、訓練時間も長くなるという問題がある。

## 手法
CLIP-Adapter は、CLIP の視覚エンコーダとテキストエンコーダを凍結し、それぞれの最終層直後にボトルネック構造を持つ軽量アダプタを追加する。視覚側のアダプタ $A_v(\cdot)$ とテキスト側のアダプタ $A_t(\cdot)$ はいずれも 2 層の線形変換で構成され、中間層に ReLU を挟む：

$$A_v(f) = \text{ReLU}(f^T W_1^v) W_2^v$$
$$A_t(W) = \text{ReLU}(W^T W_1^t) W_2^t$$

ここで $f \in \mathbb{R}^D$ は画像特徴、$W \in \mathbb{R}^{D \times K}$ はテキストエンコーダから生成されたクラス分類器重み、$W_1^v, W_2^v, W_1^t, W_2^t$ が学習対象のボトルネック線形層の重みである。

過学習を抑え元の CLIP の知識を保持するため、残差接続を導入し、残差比率 $\alpha, \beta$ でオリジナル特徴と適応後特徴を動的に混合する：

$$f^\star = \alpha A_v(f)^T + (1-\alpha)f$$
$$W^\star = \beta A_t(W)^T + (1-\beta)W$$

最終的なクラス確率 $p_i$ は CLIP と同様、$p_i = \frac{\exp(W_i^{\star\top} f^\star/\tau)}{\sum_j \exp(W_j^{\star\top} f^\star/\tau)}$ で算出される。損失関数は CLIP の対比損失に従う。学習対象パラメータはアダプタ重み $\theta = \{W_1^v, W_2^v, W_1^t, W_2^t\}$ のみであり、CLIP 全体の勾配計算は不要である。

バリアントとして、(1) 視覚アダプタのみ、(2) テキストアダプタのみ、(3) 両方を fine-tuning する 3 種類を提案している。また $\alpha, \beta$ をハイパーネットワーク $Q$ から動的に予測する学習可能形式も検討している。

## 結果
**実験設定**：11 データセット（ImageNet [9], StanfordCars [31], UCF101 [55], Caltech101 [13], Flowers102 [47], SUN397 [67], DTD [7], EuroSAT [21], FGVCAircraft [45], OxfordPets [48], Food101 [3]）で、1, 2, 4, 8, 16 shots の few-shot 設定で評価。視覚バックボーンは主に ResNet-50 [20]、テキストエンコーダは 12 層 Transformer。バッチサイズ 32、学習率 $1 \times 10^{-5}$。ボトルネック中間次元は $D/4 = 256$。

**比較対象**：Zero-shot CLIP [50]、Linear Probe CLIP [50]、CoOp [75]。

**主要な結果**：
- 11 データセットの平均精度において、CLIP-Adapter は全ショット数（1〜16 shots）で他の 3 つのベースラインを一貫して上回った。特に 1-shot、2-shot のような極限的な少数ショット設定で大きな改善幅を記録した。
- ImageNet 16-shot での精度：Zero-shot CLIP 55.41%、Linear Probe CLIP 53.44%、CoOp 60.46%、CLIP-Adapter 61.33%。
- 16-shot で Zero-shot CLIP から見た絶対改善幅は、EuroSAT, Flowers102, DTD, StanfordCars, FGVCAircraft といった fine-grained データセットで 20〜50% に達した。
- 効率性（ImageNet 16-shot）：訓練時間 50 min、GPU メモリ 2227 MiB、パラメータ 0.52 M、推論速度 10.6 ms。CoOp と比較して訓練時間 16× 削減、推論 29× 高速。
- アブレーション：ボトルネック中間次元は $D/4$ が最適（Table 5）。最適な $\alpha$ はデータセット依存であり、fine-grained な EuroSAT や DTD では 0.6〜0.8、generic な Caltech101 や ImageNet では約 0.2（Table 6）。
- 視覚バックボーンを ResNet-50, ResNet-101, ViT-B/32, ViT-B/16 の 4 種で比較した結果、CLIP-Adapter はいずれでも CoOp を上回った（Table 8）。
- 分布シフトロバスト性：ImageNet で訓練し ImageNetV2 [51], ImageNet-Sketch [23], ImageNet-A [63], ImageNet-R [22] で評価した結果、CLIP-Adapter は他手法より高い精度を維持した（Table 9）。
- 他アダプタ手法（Houlsby [24], He [19]）と比較しても、パラメータ数を大幅に抑えつつより高い精度を達成した（Table 3）。
- ELEVATER [34] ベンチマークのベースライン（R-2P, L-2P, L-1P）との比較でも CLIP-Adapter が最高精度（Table 4）。
- アダプタ挿入位置は最終層（12 層目）が最適であり、CLIP 全体の勾配伝播が不要となることで計算コストを最小化した（Table 2）。
- EuroSAT で学習した特徴多様体を t-SNE で可視化したところ、CLIP-Adapter はカテゴリ間の分離が最も明確であった（Figure 6）。

## 限界
本文からは不明。

