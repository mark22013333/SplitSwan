namespace SplitSwan.Core.Tests;

// 介面元件（同 Mac 版 DesignSystem）的純邏輯：色調圖示、動畫曲線、搖晃位移、交錯出場時間表

public class ToneStyleTests
{
    [Theory]
    [InlineData(StatusTone.Ok, ToneGlyph.CheckCircle)]
    [InlineData(StatusTone.Working, ToneGlyph.Clock)]
    [InlineData(StatusTone.Warn, ToneGlyph.Triangle)]
    [InlineData(StatusTone.Bad, ToneGlyph.Octagon)]
    [InlineData(StatusTone.Idle, ToneGlyph.DashedCircle)]
    public void Glyph_PerTone(StatusTone tone, ToneGlyph glyph) => Assert.Equal(glyph, ToneStyle.Glyph(tone));

    [Fact]
    public void FiveTones_EachHasDistinctGlyph() =>
        Assert.Equal(5, Enum.GetValues<StatusTone>().Select(ToneStyle.Glyph).Distinct().Count());

    [Fact]
    public void Working_AddedLast_ExistingValuesUnchanged()
    {
        Assert.Equal(0, (int)StatusTone.Ok);
        Assert.Equal(1, (int)StatusTone.Warn);
        Assert.Equal(2, (int)StatusTone.Bad);
        Assert.Equal(3, (int)StatusTone.Idle);
        Assert.Equal(4, (int)StatusTone.Working);
    }

    [Fact]
    public void OnlyIdleIsNeutral() =>
        Assert.Equal([StatusTone.Idle], Enum.GetValues<StatusTone>().Where(ToneStyle.IsNeutral));
}

public class MotionTests
{
    [Fact]
    public void TransitionSeconds_ReducedIsShortFade()
    {
        Assert.Equal(0.25, Motion.TransitionSeconds(false));
        Assert.Equal(0.15, Motion.TransitionSeconds(true));
    }

    [Theory]
    [InlineData(-1, 0.25, 0)]
    [InlineData(0.125, 0.25, 0.5)]
    [InlineData(1, 0.25, 1)]
    [InlineData(0, 0, 1)]
    public void Progress_Clamped(double elapsed, double duration, double expected) =>
        Assert.Equal(expected, Motion.Progress(elapsed, duration), 6);

    [Fact]
    public void EaseInOut_EndpointsMidpointAndMonotonic()
    {
        Assert.Equal(0, Motion.EaseInOut(0), 9);
        Assert.Equal(0.5, Motion.EaseInOut(0.5), 9);
        Assert.Equal(1, Motion.EaseInOut(1), 9);
        Assert.True(Motion.EaseInOut(0.1) < 0.1);   // 起頭平緩
        Assert.True(Motion.EaseInOut(0.9) > 0.9);   // 結尾平緩
        var prev = -1.0;
        for (var t = 0.0; t <= 1.0; t += 0.01)
        {
            var v = Motion.EaseInOut(t);
            Assert.True(v >= prev);
            prev = v;
        }
    }

    [Fact]
    public void Shake_StartsAndEndsAtRest_PeaksAtTravel()
    {
        Assert.Equal(0, Motion.ShakeOffset(0, false));
        Assert.Equal(0, Motion.ShakeOffset(1, false));
        // 3 次＝sin 走 6π：第一個波峰在 1/12
        Assert.Equal(6, Motion.ShakeOffset(1.0 / 12, false), 6);
        Assert.Equal(-6, Motion.ShakeOffset(3.0 / 12, false), 6);
        var samples = Enumerable.Range(1, 99).Select(i => Motion.ShakeOffset(i / 100.0, false)).ToList();
        Assert.All(samples, v => Assert.InRange(v, -6.0000001, 6.0000001));
        // 左右各晃 3 次：六個波峰依序右左右左右左
        var peaks = Enumerable.Range(0, 6).Select(k => Math.Sign(Motion.ShakeOffset((2 * k + 1) / 12.0, false)));
        Assert.Equal([1, -1, 1, -1, 1, -1], peaks);
    }

    [Fact]
    public void Shake_ReducedMotion_NeverMoves() =>
        Assert.All(Enumerable.Range(0, 101), i => Assert.Equal(0, Motion.ShakeOffset(i / 100.0, true)));

    [Fact]
    public void Shake_TotalIsPoint3Seconds() => Assert.Equal(0.3, Motion.ShakeDuration);

    [Theory]
    [InlineData(0, 0)]
    [InlineData(1, 0.04)]
    [InlineData(5, 0.2)]
    [InlineData(6, 0.24)]
    [InlineData(7, 0.25)]
    [InlineData(100, 0.25)]
    public void StaggerDelay_StepAndCap(int index, double expected) =>
        Assert.Equal(expected, Motion.StaggerDelay(index, false), 9);

    [Fact]
    public void StaggerDelay_ReducedMotion_AllAtOnce() =>
        Assert.All(Enumerable.Range(0, 20), i => Assert.Equal(0, Motion.StaggerDelay(i, true)));

    [Fact]
    public void StaggerFrame_BeforeDelayHiddenAndOffset_AfterSettled()
    {
        var before = Motion.StaggerFrame(3, 0.05, false);   // 第 4 項延遲 0.12 秒，還沒開始
        Assert.Equal((0.0, 6.0), before);
        var after = Motion.StaggerFrame(3, 0.12 + 0.25, false);
        Assert.Equal(1, after.Opacity, 9);
        Assert.Equal(0, after.OffsetY, 9);
        var mid = Motion.StaggerFrame(0, 0.125, false);
        Assert.Equal(0.5, mid.Opacity, 9);
        Assert.Equal(3, mid.OffsetY, 9);
    }

    [Fact]
    public void StaggerFrame_Reduced_FadeOnlyNoOffset()
    {
        var f = Motion.StaggerFrame(10, 0.075, true);
        Assert.Equal(0.5, f.Opacity, 9);
        Assert.Equal(0, f.OffsetY);
    }

    [Theory]
    [InlineData(0, false, 0)]
    [InlineData(1, false, 0.25)]
    [InlineData(3, false, 0.33)]
    [InlineData(50, false, 0.5)]
    [InlineData(50, true, 0.15)]
    public void StaggerTotal(int count, bool reduced, double expected) =>
        Assert.Equal(expected, Motion.StaggerTotal(count, reduced), 9);
}
