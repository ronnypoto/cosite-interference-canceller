function [I_out, Q_out] = fcn(Error_Power)
% LP-V17b - ADAPTIVE-INTEGRATION PATTERN SEARCH (scale-invariant reset)
%
% Same proven search as LP-V17. ONE change: the reset/hop detector no longer
% uses an absolute "Error_Power > 1e6" trip (which a gain or level change can
% latch on forever, resetting to I=Q=0 every step = 0 dB). It now re-inits
% only on a large, SUSTAINED jump above the established start power, so a
% level change or a single noise spike cannot trip it.
%
% NOTE - THIS DOES NOT FIX A BLIND DETECTOR. If the residual is attenuated
% relative to the added detector noise before they are summed, the measured
% power carries almost no information about the residual and no algorithm can
% null. Keep the residual at full scale into the noise adder, and set the
% noise floor ~25-30 dB below the uncancelled reading.
%
% RUN SETTINGS: T_sim = 0.030. Measure the last 8 ms.

persistent I Q StepSize DirState LastPower initialized ...
           StallCycles BestI BestQ locked WaitTimer ...
           phase InitPower Dwell Kicked WinStreak ...
           AvgAcc AvgCnt AvgTarget HopCnt

DWELL_LEN = 2;
DAC_LSB   = 0.0005;

% --- 1. STATE INIT + SCALE-INVARIANT RESET ------------------------------
%   Simulink Coder requires every persistent to be assigned before it is
%   read (only an isempty() check may come first). So the order is:
%     (1) initialize on the first call, under isempty(initialized);
%     (2) test for a hop using the now-assigned persistents;
%     (3) re-init if a hop is confirmed.
%   Do NOT read persistents in a reset CONDITION before block (1) runs.

% (1) First-call initialization -- assigns every persistent.
if isempty(initialized)
    I = 0; Q = 0;
    StepSize = 0.20; DirState = 1;
    LastPower = 1e12;
    StallCycles = 0;
    BestI = 0; BestQ = 0;
    locked = false;
    WaitTimer = 0;
    phase = 1;
    InitPower = 1e-15;
    Dwell = 0;
    Kicked = false;
    WinStreak = 0;
    AvgAcc = 0; AvgCnt = 0; AvgTarget = 1;
    HopCnt = 0;
    initialized = 1;
end

% (2) Hop/reset detector: scale-invariant and sustained. All persistents are
%     assigned by now. Active only after startup so it cannot false-fire
%     while InitPower is still being captured. Referenced to InitPower, so it
%     never trips in a healthy single-frequency run. (For the agile multi-hop
%     sim, reference the locked null power, e.g. LastPower, instead.)
resetNow = false;
if WaitTimer >= 30 && InitPower > 1e-12
    if Error_Power > 8 * InitPower
        HopCnt = HopCnt + 1;
    else
        HopCnt = 0;
    end
    if HopCnt >= 8
        resetNow = true;
    end
end

% (3) Re-initialize on a confirmed hop.
if resetNow
    I = 0; Q = 0;
    StepSize = 0.20; DirState = 1;
    LastPower = 1e12;
    StallCycles = 0;
    BestI = 0; BestQ = 0;
    locked = false;
    WaitTimer = 0;
    phase = 1;
    InitPower = 1e-15;
    Dwell = 0;
    Kicked = false;
    WinStreak = 0;
    AvgAcc = 0; AvgCnt = 0; AvgTarget = 1;
    HopCnt = 0;
end

% --- 2. STARTUP: settle, capture the initial power ---
WaitTimer = WaitTimer + 1;
if WaitTimer < 30
    LastPower = Error_Power;
    if WaitTimer >= 20 && Error_Power > InitPower
        InitPower = Error_Power;
    end
    I_out = I; Q_out = Q;
    return;
end
if InitPower < 1e-15
    InitPower = 1e-15;
end

% --- 3. LOCKED: hold the best point ---
if locked
    I_out = BestI; Q_out = BestQ;
    return;
end

% --- 4. DWELL: let the error filter settle after a move ---
if Dwell > 0
    Dwell = Dwell - 1;
    I_out = I; Q_out = Q;
    return;
end

% --- 5. ADAPTIVE INTEGRATION -------------------------------------------
%   Average more samples as the residual gets closer to the floor.
%   SNR improves as sqrt(N), so deep nulls become measurable.
AvgAcc = AvgAcc + Error_Power;
AvgCnt = AvgCnt + 1;
if AvgCnt < AvgTarget
    I_out = I; Q_out = Q;
    return;
end
P = AvgAcc / AvgCnt;
AvgAcc = 0; AvgCnt = 0;

% integration depth for the NEXT reading, based on how deep we are now
depth = P / InitPower;              % 1.0 at start, shrinks as we null
if depth > 0.05                     % shallower than ~13 dB
    AvgTarget = 1;                  %   fast, coarse
elseif depth > 0.01                 % 13-20 dB
    AvgTarget = 2;
elseif depth > 0.002                % 20-27 dB
    AvgTarget = 4;
elseif depth > 0.0005               % 27-33 dB
    AvgTarget = 8;
else                                % deeper than 33 dB
    AvgTarget = 16;                 %   slow, quiet, precise
end

% --- 6. STEP-SIZE LAW (scale-invariant, from V15) -----------------------
TargetStep = DAC_LSB;
if phase == 1
    TargetStep = 0.20 * sqrt(P / InitPower);
    if TargetStep < DAC_LSB
        TargetStep = DAC_LSB;
    elseif TargetStep > 0.25
        TargetStep = 0.25;
    end
end

% --- 7. ADAPTIVE MARGIN -------------------------------------------------
%   More averaging -> quieter measurement -> smaller wins can be trusted.
margin = 1.0 - 0.004 / sqrt(AvgTarget);
if margin > 0.9995
    margin = 0.9995;
end

% --- 8. 8-WAY PATTERN SEARCH WITH MOMENTUM ------------------------------
if P < LastPower * margin
    LastPower = P;
    StallCycles = 0;
    Kicked = false;
    BestI = I;
    BestQ = Q;
    WinStreak = WinStreak + 1;

    if phase == 1
        StepSize = TargetStep;
        if WinStreak >= 2
            StepSize = StepSize * 2;
        end
        if StepSize > 0.25
            StepSize = 0.25;
        end
    else
        if WinStreak >= 2
            StepSize = StepSize * 2.0;
        else
            StepSize = StepSize * 1.6;
        end
        if StepSize > 0.04
            StepSize = 0.04;
        end
    end
else
    WinStreak = 0;
    dI = 0; dQ = 0;
    if DirState == 1,     dI =  1;
    elseif DirState == 2, dI = -1;
    elseif DirState == 3, dQ =  1;
    elseif DirState == 4, dQ = -1;
    elseif DirState == 5, dI =  1; dQ =  1;
    elseif DirState == 6, dI =  1; dQ = -1;
    elseif DirState == 7, dI = -1; dQ =  1;
    elseif DirState == 8, dI = -1; dQ = -1;
    end
    I = I - StepSize * dI;
    Q = Q - StepSize * dQ;
    DirState = DirState + 1;

    if DirState > 8
        DirState = 1;
        StallCycles = StallCycles + 1;
        I = BestI;
        Q = BestQ;

        if phase == 1
            StepSize = StepSize * 0.5;
            if StepSize < TargetStep
                StepSize = TargetStep;
            end
            if StallCycles >= 3
                if LastPower < 0.25 * InitPower
                    phase = 2;
                    StallCycles = 0;
                    Kicked = false;
                else
                    StepSize = 0.20;
                    StallCycles = 0;
                end
            end
        else
            StepSize = StepSize * 0.5;
            if StepSize < DAC_LSB
                StepSize = DAC_LSB;
            end
            if StallCycles == 4 && ~Kicked
                StepSize = StepSize * 8;
                if StepSize < 0.01
                    StepSize = 0.01;
                end
                if StepSize > 0.04
                    StepSize = 0.04;
                end
                Kicked = true;
            end
            if StallCycles >= 8 && StepSize <= 1.5*DAC_LSB && AvgTarget >= 8
                locked = true;
                I_out = BestI; Q_out = BestQ;
                return;
            end
        end
    end
end

% --- 9. APPLY THE NEXT TRIAL STEP ---------------------------------------
dI = 0; dQ = 0;
if DirState == 1,     dI =  1;
elseif DirState == 2, dI = -1;
elseif DirState == 3, dQ =  1;
elseif DirState == 4, dQ = -1;
elseif DirState == 5, dI =  1; dQ =  1;
elseif DirState == 6, dI =  1; dQ = -1;
elseif DirState == 7, dI = -1; dQ =  1;
elseif DirState == 8, dI = -1; dQ = -1;
end
I = I + StepSize * dI;
Q = Q + StepSize * dQ;

% --- 10. LIMITS + DWELL --------------------------------------------------
if I >  1, I =  1; end
if I < -1, I = -1; end
if Q >  1, Q =  1; end
if Q < -1, Q = -1; end
Dwell = DWELL_LEN;

I_out = I;
Q_out = Q;
end
