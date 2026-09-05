%% Cancellation Depth vs Interferer Frequency  -  SWEEP TEST
%  Co-Site Interference Canceller, 30-88 MHz
%  Ronny Pustilnik / Adir Lemaer - Afeka
%
%  WHAT THIS PROVES
%    The quarter-wave arm and the main-path delay are FIXED lengths. They
%    give a true 90 deg / matched delay at ONE frequency only (the design
%    point, 57 MHz). This script holds those fixed and sweeps the interferer
%    across the band, measuring how much cancellation is actually reachable
%    at each frequency.
%
%    The resulting curve is the honest answer to "what is the operating
%    bandwidth" - deep null near the design point, tapering toward 30 and
%    88 MHz. It is also the figure that explains the simulation-vs-hardware
%    gap in terms of a specific physical cause.
%
%  IMPORTANT: the tactical signal is switched OFF for this sweep. The
%  detector is wideband, so a -20 dBm wanted tone would floor the residual
%  measurement and mask the true null depth. Interferer only = clean number.

clear; clc;
model_name = 'project';

% =========================================================================
% --- 1. Sweep configuration ---
% =========================================================================
Freq_Design   = 57e6;                                   % what the cables are cut for
Freq_List     = [30 35 40 45 50 57 62 70 78 88] * 1e6;  % sweep points

T_sim         = 0.010;      % 10 ms per run
SPP           = 8;          % samples per period at the DESIGN frequency
Fs            = SPP * Freq_Design;   % FIXED for the whole sweep (456 MHz)
Ts            = 1/Fs;

Amp_Interferer = 0.3162;    %   0 dBm
Amp_Signal     = 0;         % tactical OFF - see note above

% Fixed hardware delays - these do NOT change across the sweep. That is the
% whole point of the experiment.
Td_Quarter    = 1/(4*Freq_Design);          % 4.386 ns
N_Quarter     = round(Td_Quarter * Fs);     % = 2 samples exactly
Delay_Seconds = 4e-9;
N_MainDelay   = round(Delay_Seconds * Fs);

% Measurement windows (fractions of the run)
WIN_INIT      = 0.10;       % first 10% = uncancelled plateau
WIN_FINAL     = 0.10;       % last  10% = converged null

fprintf('Sweep: %d frequencies, %.0f ms each, Fs = %.1f MHz\n', ...
        numel(Freq_List), T_sim*1e3, Fs/1e6);
fprintf('Design point %.1f MHz -> quarter-wave = %d samples (held fixed)\n\n', ...
        Freq_Design/1e6, N_Quarter);

% =========================================================================
% --- 2. Prepare the model ---
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
Depth_dB   = nan(size(Freq_List));
P_init_all = nan(size(Freq_List));
P_finl_all = nan(size(Freq_List));

% =========================================================================
% --- 3. Run the sweep ---
% =========================================================================
for k = 1:numel(Freq_List)

    Freq_Interferer = Freq_List(k);
    Freq_Signal     = Freq_Interferer;   % unused while Amp_Signal = 0

    % rebuild the sources in the base workspace for the From Workspace blocks
    Interferer_Data = [t, Amp_Interferer * sin(2*pi*Freq_Interferer * t)];
    Tactical_Data   = [t, zeros(size(t))];

    assignin('base','Interferer_Data', Interferer_Data);
    assignin('base','Tactical_Data',   Tactical_Data);
    assignin('base','Freq_Interferer', Freq_Interferer);
    assignin('base','Freq_Signal',     Freq_Signal);
    assignin('base','Td_Quarter',      Td_Quarter);
    assignin('base','N_Quarter',       N_Quarter);
    assignin('base','Delay_Seconds',   Delay_Seconds);
    assignin('base','N_MainDelay',     N_MainDelay);
    assignin('base','Ts',              Ts);
    assignin('base','Fs',              Fs);

    fprintf('  [%2d/%2d] %5.1f MHz ... ', k, numel(Freq_List), Freq_Interferer/1e6);

    try
        out = sim(model_name);
    catch ME
        fprintf('SIM FAILED: %s\n', ME.message);
        continue;
    end

    % --- pull the error power log ---
    E = [];
    if isprop(out,'Error_Log') || isfield(out,'Error_Log')
        raw = out.Error_Log;
        if isa(raw,'timeseries')
            E = raw.Data(:);
        elseif isstruct(raw) && isfield(raw,'Data')
            E = raw.Data(:);
        else
            E = raw(:);
        end
    end

    if isempty(E) || numel(E) < 20
        fprintf('no Error_Log data\n');
        continue;
    end

    n   = numel(E);
    nI  = max(1, round(WIN_INIT  * n));
    nF  = max(1, round(WIN_FINAL * n));

    P_init  = median(E(1:nI));           % uncancelled plateau
    P_final = median(E(end-nF+1:end));   % converged null

    P_init_all(k) = P_init;
    P_finl_all(k) = P_final;

    if P_final > 0 && P_init > 0
        Depth_dB(k) = 10*log10(P_init / P_final);
        fprintf('depth = %5.1f dB\n', Depth_dB(k));
    else
        fprintf('bad power values (init=%g final=%g)\n', P_init, P_final);
    end
end

% =========================================================================
% --- 4. Results table ---
% =========================================================================
fprintf('\n================ CANCELLATION vs FREQUENCY ================\n');
fprintf('  Design point: %.1f MHz (fixed quarter-wave + delay)\n', Freq_Design/1e6);
fprintf('  %-12s %-14s %-14s %-10s\n','Freq [MHz]','P_uncanc','P_null','Depth [dB]');
for k = 1:numel(Freq_List)
    fprintf('  %-12.1f %-14.4g %-14.4g %-10.1f\n', ...
        Freq_List(k)/1e6, P_init_all(k), P_finl_all(k), Depth_dB(k));
end

valid = ~isnan(Depth_dB);
if any(valid)
    [best, ib] = max(Depth_dB(valid));
    fl = Freq_List(valid);
    fprintf('\n  Best: %.1f dB at %.1f MHz\n', best, fl(ib)/1e6);
    fprintf('  Mean across band: %.1f dB\n', mean(Depth_dB(valid)));
    above15 = fl(Depth_dB(valid) >= 15);
    if ~isempty(above15)
        fprintf('  >= 15 dB from %.1f to %.1f MHz\n', min(above15)/1e6, max(above15)/1e6);
    end
end

% =========================================================================
% --- 5. Plot ---
% =========================================================================
figure('Color','w','Name','Cancellation vs Frequency');
plot(Freq_List/1e6, Depth_dB, '-o', 'LineWidth', 1.8, 'MarkerFaceColor','w');
grid on; hold on;
xline(Freq_Design/1e6, '--', sprintf('design %.0f MHz', Freq_Design/1e6), ...
      'LabelVerticalAlignment','bottom');
yline(15, ':', '15 dB target');
xlabel('Interferer frequency [MHz]');
ylabel('Cancellation depth [dB]');
title('Cancellation depth vs frequency (fixed \lambda/4 and delay)');
xlim([min(Freq_List) max(Freq_List)]/1e6);

% save for the report
save('sweep_results.mat','Freq_List','Depth_dB','P_init_all','P_finl_all', ...
     'Freq_Design','Td_Quarter','T_sim','Fs');
fprintf('\nSaved: sweep_results.mat\n');
