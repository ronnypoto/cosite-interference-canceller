%% Two-Tone Study: separation (df) and power ratio vs depth & convergence time
%  Co-Site Interference Canceller, 30-88 MHz
%  Ronny Pustilnik / Adir Lemaer - Afeka
%
%  WHAT THIS MEASURES
%    The detector (u^2 -> leaky integrator) is a TOTAL POWER detector. It
%    cannot separate the wanted tone from the interferer residual. Two
%    consequences, and this script quantifies both:
%
%    (A) POWER-RATIO FLOOR. Once the interferer residual falls below the
%        wanted-signal power, the detector is reading the wanted tone and
%        the gradient dies. Cancellation stalls near the interferer/wanted
%        power ratio, NOT at the hardware ceiling.
%
%    (B) BEAT RIPPLE. The residual carries a beat at df = |f_int - f_sig|.
%        If df falls near or below the detector video bandwidth, that beat
%        survives the filter and corrupts every measurement -> slower and
%        shallower convergence. Video BW here ~ (1-pole)/(2*pi*Ts_filt).
%
%  OUTPUTS: final depth and time-to-threshold vs df, and vs power ratio.

clear; clc;
model_name = 'project';

% =========================================================================
% --- 1. Configuration ---
% =========================================================================
Freq_Design    = 57e6;          % cables cut for this
Freq_Interferer= 57e6;          % interferer stays put
Amp_Interferer = 0.3162;        % 0 dBm

T_sim          = 0.015;         % 15 ms - long enough to stall/settle
SPP            = 16;
Fs             = SPP * Freq_Design;
Ts             = 1/Fs;

% Fixed hardware delays (design point)
Td_Quarter     = 1/(4*Freq_Design);
N_Quarter      = round(Td_Quarter * Fs);
Delay_Seconds  = 4e-9;
N_MainDelay    = round(Delay_Seconds * Fs);

% --- STUDY A: separation sweep (wanted fixed at -20 dBm) ---
df_List        = [10e3 30e3 100e3 300e3 1e6 3e6 10e6 17e6];
Amp_Signal_A   = 0.0316;        % -20 dBm

% --- STUDY B: power-ratio sweep (df fixed and large) ---
df_B           = 17e6;                              % well clear of any beat
SIR_dB_List    = [-40 -30 -20 -15 -10];             % wanted power re: interferer
% wanted amplitude = interferer amplitude * 10^(SIR/20)

% Thresholds we time
THRESH_dB      = [10 15 20];

% Measurement windows
WIN_INIT       = 0.08;
WIN_FINAL      = 0.10;

% =========================================================================
% --- 2. Prepare model ---
% =========================================================================
load_system(model_name);
set_param(model_name,'SolverType','Fixed-step');
set_param(model_name,'Solver','FixedStepDiscrete');
set_param(model_name,'FixedStep', num2str(Ts,'%.12g'));
set_param(model_name,'StopTime',  num2str(T_sim,'%.12g'));
set_param(model_name,'SignalLogging','off');
set_param(model_name,'SaveOutput','on');
set_param(model_name,'SaveTime','on');      % need time for convergence timing
set_param(model_name,'Decimation','20');

t = (0:Ts:T_sim-Ts)';

% =========================================================================
% --- 3. Helper: run one case, return depth + time-to-threshold ---
% =========================================================================
    function [depth_dB, t_thresh, Evec, tvec] = run_case(mdl, tt, Tsim, ...
             fInt, aInt, fSig, aSig, vars, winI, winF, thr)
        Interferer_Data = [tt, aInt * sin(2*pi*fInt * tt)];
        if aSig > 0
            Tactical_Data = [tt, aSig * sin(2*pi*fSig * tt)];
        else
            Tactical_Data = [tt, zeros(size(tt))];
        end
        assignin('base','Interferer_Data', Interferer_Data);
        assignin('base','Tactical_Data',   Tactical_Data);
        assignin('base','Freq_Interferer', fInt);
        assignin('base','Freq_Signal',     fSig);
        fn = fieldnames(vars);
        for ii = 1:numel(fn)
            assignin('base', fn{ii}, vars.(fn{ii}));
        end

        depth_dB = NaN; t_thresh = nan(size(thr)); Evec = []; tvec = [];
        try
            out = sim(mdl);
        catch ME
            fprintf('SIM FAILED: %s\n', ME.message);
            return;
        end

        raw = [];
        try, raw = out.Error_Log; catch, end
        if isempty(raw), return; end
        if isa(raw,'timeseries')
            Evec = raw.Data(:); tvec = raw.Time(:);
        elseif isstruct(raw) && isfield(raw,'Data')
            Evec = raw.Data(:);
            if isfield(raw,'Time'), tvec = raw.Time(:); end
        else
            Evec = raw(:);
        end
        if isempty(tvec)
            tvec = (0:numel(Evec)-1)' * (Tsim/max(numel(Evec)-1,1));
        end
        if numel(Evec) < 20, return; end

        n  = numel(Evec);
        nI = max(1, round(winI*n));
        nF = max(1, round(winF*n));
        P0 = median(Evec(1:nI));
        Pf = median(Evec(end-nF+1:end));
        if P0 > 0 && Pf > 0
            depth_dB = 10*log10(P0/Pf);
        end

        % time to first SUSTAINED threshold crossing, ignoring the startup
        % region (where the filter has not charged and P is meaninglessly low)
        dcurve = 10*log10(P0 ./ max(Evec, eps));
        iStart = nI + 1;          % skip the uncancelled plateau window
        HOLD   = 5;               % must stay above threshold this many samples
        for j = 1:numel(thr)
            idx = [];
            for ii = iStart:(numel(dcurve)-HOLD)
                if all(dcurve(ii:ii+HOLD-1) >= thr(j))
                    idx = ii; break;
                end
            end
            if ~isempty(idx), t_thresh(j) = tvec(idx); end
        end
    end

vars = struct('Td_Quarter',Td_Quarter,'N_Quarter',N_Quarter, ...
              'Delay_Seconds',Delay_Seconds,'N_MainDelay',N_MainDelay, ...
              'Ts',Ts,'Fs',Fs);

% =========================================================================
% --- 4. STUDY A: separation sweep ---
% =========================================================================
fprintf('\n===== STUDY A: separation sweep (wanted = -20 dBm) =====\n');
depthA = nan(size(df_List));
tA     = nan(numel(df_List), numel(THRESH_dB));

for k = 1:numel(df_List)
    fSig = Freq_Interferer - df_List(k);
    fprintf('  df = %8.1f kHz (wanted %6.3f MHz) ... ', df_List(k)/1e3, fSig/1e6);
    [d, tt_] = run_case(model_name, t, T_sim, Freq_Interferer, Amp_Interferer, ...
                        fSig, Amp_Signal_A, vars, WIN_INIT, WIN_FINAL, THRESH_dB);
    depthA(k)  = d;
    tA(k,:)    = tt_;
    fprintf('depth %5.1f dB', d);
    if ~isnan(tt_(2)), fprintf(' | t(15dB) = %5.2f ms', tt_(2)*1e3); end
    fprintf('\n');
end

% =========================================================================
% --- 5. STUDY B: power-ratio sweep ---
% =========================================================================
fprintf('\n===== STUDY B: power-ratio sweep (df = %.1f MHz) =====\n', df_B/1e6);
depthB = nan(size(SIR_dB_List));
tB     = nan(numel(SIR_dB_List), numel(THRESH_dB));
fSigB  = Freq_Interferer - df_B;

for k = 1:numel(SIR_dB_List)
    aSig = Amp_Interferer * 10^(SIR_dB_List(k)/20);
    fprintf('  wanted %4d dB below interferer ... ', SIR_dB_List(k));
    [d, tt_] = run_case(model_name, t, T_sim, Freq_Interferer, Amp_Interferer, ...
                        fSigB, aSig, vars, WIN_INIT, WIN_FINAL, THRESH_dB);
    depthB(k) = d;
    tB(k,:)   = tt_;
    fprintf('depth %5.1f dB\n', d);
end

% =========================================================================
% --- 6. Report ---
% =========================================================================
fprintf('\n============ STUDY A: depth & timing vs separation ============\n');
fprintf('  %-12s %-10s %-10s %-10s %-10s\n','df [kHz]','depth[dB]','t10[ms]','t15[ms]','t20[ms]');
for k = 1:numel(df_List)
    fprintf('  %-12.1f %-10.1f %-10.2f %-10.2f %-10.2f\n', df_List(k)/1e3, ...
        depthA(k), tA(k,1)*1e3, tA(k,2)*1e3, tA(k,3)*1e3);
end

fprintf('\n============ STUDY B: depth vs power ratio ============\n');
fprintf('  %-14s %-10s %-10s\n','wanted [dB]','depth[dB]','t15[ms]');
for k = 1:numel(SIR_dB_List)
    fprintf('  %-14d %-10.1f %-10.2f\n', SIR_dB_List(k), depthB(k), tB(k,2)*1e3);
end
fprintf('\n  PREDICTION: depth should track the power ratio - a wanted tone\n');
fprintf('  X dB below the interferer floors cancellation near X dB.\n');

% =========================================================================
% --- 7. Plots ---
% =========================================================================
figure('Color','w','Name','Two-tone study');

subplot(1,3,1);
semilogx(df_List/1e3, depthA, '-o','LineWidth',1.8,'MarkerFaceColor','w'); grid on;
xlabel('separation \Deltaf [kHz]'); ylabel('depth [dB]');
title('Depth vs separation'); yline(20,':','power-ratio floor');

subplot(1,3,2);
semilogx(df_List/1e3, tA(:,2)*1e3, '-o','LineWidth',1.8,'MarkerFaceColor','w'); grid on;
xlabel('separation \Deltaf [kHz]'); ylabel('time to 15 dB [ms]');
title('Convergence vs separation');

subplot(1,3,3);
plot(SIR_dB_List, depthB, '-s','LineWidth',1.8,'MarkerFaceColor','w'); grid on; hold on;
plot(SIR_dB_List, -SIR_dB_List, '--k');
xlabel('wanted level re: interferer [dB]'); ylabel('depth [dB]');
title('Depth vs power ratio'); legend('measured','ideal = ratio','Location','best');

save('twotone_results.mat','df_List','depthA','tA','SIR_dB_List','depthB','tB','THRESH_dB');
fprintf('\nSaved: twotone_results.mat\n');
