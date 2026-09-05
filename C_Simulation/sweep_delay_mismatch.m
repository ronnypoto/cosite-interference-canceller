%% Delay Mismatch Sweep - how precisely must the cables be matched?
%  Co-Site Interference Canceller - Ronny / Adir, Afeka
%
%  SETUP BEFORE RUNNING:
%    Set the MAIN-PATH delay block's "Time delay" field to:   Delay_Main
%    (Transport Delay block. If the solver complains about continuous
%     states, switch Solver to ode4, or use a Variable Transport Delay.)
%
%  WHAT IT ANSWERS
%    At the bench you are grabbing cables off the wall, not cutting to a
%    measured length. This tells you how many ns of main-vs-reference delay
%    error you can tolerate before cancellation depth collapses - i.e.
%    whether "roughly the right length" is good enough.
%
%    1 ns of coax ~ 20 cm of RG-58/RG-316 (VF ~ 0.66). So the tolerance in
%    ns converts directly into a cable-length tolerance in cm.
%
%  Interferer only (wanted OFF) so the depth number is clean.

clear; clc;
model_name = 'project';

% =========================================================================
% --- 1. Config (kept small/fast) ---
% =========================================================================
Freq_Design     = 57e6;
Freq_Interferer = 57e6;
Freq_Signal     = 40e6;         % unused, wanted is off
Amp_Interferer  = 0.3162;       % 0 dBm
Amp_Signal      = 0;            % wanted OFF for a clean depth reading

T_sim           = 0.010;        % 10 ms
SPP             = 16;           % 16 samples/period -> Ts = 1.096 ns
Fs              = SPP * Freq_Design;
Ts              = 1/Fs;

Delay_Nominal   = 4e-9;         % your matched/design main-path delay
Offsets_ns      = [-5 -3 -2 -1 -0.5 0 0.5 1 2 3 5];

% Fixed quarter-wave arm (design point) - unchanged across the sweep
Td_Quarter      = 1/(4*Freq_Design);
N_Quarter       = round(Td_Quarter * Fs);

WIN_INIT        = 0.10;
WIN_FINAL       = 0.10;

fprintf('Delay mismatch sweep: %d points, %.0f ms each\n', numel(Offsets_ns), T_sim*1e3);
fprintf('Nominal main delay %.2f ns | Ts = %.3f ns | quarter-wave = %d samples\n\n', ...
        Delay_Nominal*1e9, Ts*1e9, N_Quarter);

% =========================================================================
% --- 2. Model setup ---
% =========================================================================
load_system(model_name);
set_param(model_name,'SolverType','Fixed-step');
set_param(model_name,'Solver','FixedStepDiscrete');
set_param(model_name,'FixedStep', num2str(Ts,'%.12g'));
set_param(model_name,'StopTime',  num2str(T_sim,'%.12g'));
set_param(model_name,'SignalLogging','off');
set_param(model_name,'SaveOutput','on');
set_param(model_name,'Decimation','20');

t = (0:Ts:T_sim-Ts)';
Interferer_Data = [t, Amp_Interferer * sin(2*pi*Freq_Interferer * t)];
Tactical_Data   = [t, zeros(size(t))];

Depth_dB = nan(size(Offsets_ns));

% =========================================================================
% --- 3. Sweep ---
% =========================================================================
for k = 1:numel(Offsets_ns)

    Delay_Main = Delay_Nominal + Offsets_ns(k)*1e-9;
    if Delay_Main < 0, Delay_Main = 0; end

    assignin('base','Interferer_Data', Interferer_Data);
    assignin('base','Tactical_Data',   Tactical_Data);
    assignin('base','Delay_Main',      Delay_Main);
    assignin('base','Delay_Seconds',   Delay_Main);   % in case the block uses this name
    assignin('base','Td_Quarter',      Td_Quarter);
    assignin('base','N_Quarter',       N_Quarter);
    assignin('base','Freq_Interferer', Freq_Interferer);
    assignin('base','Freq_Signal',     Freq_Signal);
    assignin('base','Ts',              Ts);
    assignin('base','Fs',              Fs);

    fprintf('  offset %+5.1f ns (delay %5.2f ns) ... ', Offsets_ns(k), Delay_Main*1e9);

    try
        out = sim(model_name);
    catch ME
        fprintf('SIM FAILED: %s\n', ME.message);
        continue;
    end

    E = [];
    try
        raw = out.Error_Log;
        if isa(raw,'timeseries')
            E = raw.Data(:);
        elseif isstruct(raw) && isfield(raw,'Data')
            E = raw.Data(:);
        else
            E = raw(:);
        end
    catch
    end
    if isempty(E) || numel(E) < 20
        fprintf('no Error_Log\n'); continue;
    end

    n  = numel(E);
    nI = max(1, round(WIN_INIT *n));
    nF = max(1, round(WIN_FINAL*n));
    P0 = median(E(1:nI));
    Pf = median(E(end-nF+1:end));

    if P0 > 0 && Pf > 0
        Depth_dB(k) = 10*log10(P0/Pf);
        fprintf('depth = %5.1f dB\n', Depth_dB(k));
    else
        fprintf('bad powers\n');
    end
end

% =========================================================================
% --- 4. Report + tolerance ---
% =========================================================================
fprintf('\n========== DEPTH vs DELAY MISMATCH ==========\n');
fprintf('  %-12s %-12s %-10s\n','offset[ns]','cable[cm]','depth[dB]');
for k = 1:numel(Offsets_ns)
    fprintf('  %-12.1f %-12.1f %-10.1f\n', Offsets_ns(k), Offsets_ns(k)*20, Depth_dB(k));
end

valid = ~isnan(Depth_dB);
if any(valid)
    best = max(Depth_dB(valid));
    fprintf('\n  Peak depth: %.1f dB\n', best);
    for drop = [3 6 10]
        ok = Offsets_ns(valid & (Depth_dB >= best-drop));
        if ~isempty(ok)
            fprintf('  Within %2d dB of peak: %+.1f to %+.1f ns  (~%.0f to %.0f cm of cable)\n', ...
                drop, min(ok), max(ok), min(ok)*20, max(ok)*20);
        end
    end
end

% =========================================================================
% --- 5. Plot ---
% =========================================================================
figure('Color','w','Name','Depth vs delay mismatch');
plot(Offsets_ns, Depth_dB, '-o','LineWidth',1.8,'MarkerFaceColor','w'); grid on; hold on;
xline(0,'--','matched');
yline(15,':','15 dB target');
xlabel('main-path delay error [ns]   (1 ns \approx 20 cm of coax)');
ylabel('cancellation depth [dB]');
title('Cancellation depth vs main/reference delay mismatch');

save('delay_mismatch_results.mat','Offsets_ns','Depth_dB','Delay_Nominal','T_sim','Fs');
fprintf('\nSaved: delay_mismatch_results.mat\n');
