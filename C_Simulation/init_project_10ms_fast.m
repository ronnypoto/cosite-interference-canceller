%% RF Project Initialization - Digital Twin Baseband  (FAST 10 ms build)
%  Co-Site Interference Canceller, 30-88 MHz
%  Ronny Pustilnik / Adir Lemaer - Afeka
%
%  SPEED NOTES (why this runs much faster than the 40 ms version):
%    1. T_sim 40 ms -> 10 ms                    : 4x fewer samples
%    2. Fs tied to the interferer (8 samples/period) instead of a flat
%       500 MHz. This ALSO makes the quarter-wave delay an EXACT integer
%       number of samples, so the Q arm can use a discrete Integer Delay
%       block (fast, no continuous solver) instead of a Transport Delay.
%    3. Logging decimated + signal logging off  : the scopes/To-Workspace
%       blocks storing millions of points are usually the real bottleneck.
%    4. Fixed-step discrete solver at Ts        : no solver step search.

clear; clc; bdclose('all');
disp('Initializing RF Cancellation Digital Twin (fast 10 ms build)...');

% =========================================================================
% --- 1. Signal Parameters (50-Ohm system) ---
% =========================================================================
Freq_Signal     = 40e6;     % 40 MHz  - desired tactical signal
Freq_Interferer = 57e6;     % 57 MHz  - co-site interferer (band centre)

% dBm -> Vpk :  Vrms = sqrt(P_W * 50) ,  Vpk = Vrms * sqrt(2)
Amp_Signal      = 0.0316;   % -20 dBm - tactical signal floor
Amp_Interferer  = 0.3162;   %   0 dBm - co-site interferer

% =========================================================================
% --- 2. Master Timing ---
% =========================================================================
% Fs is locked to the interferer so that:
%   samples per RF period      = SPP  (fidelity knob)
%   quarter-wave delay samples = SPP/4  -> INTEGER when SPP is a multiple of 4
SPP   = 8;                          % 8 = fast, 16 = smoother RF (2x slower)
Fs    = SPP * Freq_Interferer;      % 456 MHz with SPP = 8
Ts    = 1/Fs;
T_sim = 0.010;                      % 10 ms
t     = (0:Ts:T_sim-Ts)';

% =========================================================================
% --- 3. Hardware Architecture Settings ---
% =========================================================================
Delay_Seconds  = 4e-9;              % physical RG-316 main-path delay line
Coupling_Gain  = 0.1;               % -20 dB directional coupler

% Quarter-wave (90 deg) arm for the Q channel, at the design frequency
Td_Quarter     = 1/(4*Freq_Interferer);     % 4.386 ns at 57 MHz
N_Quarter      = round(Td_Quarter * Fs);    % = SPP/4 = 2 samples exactly

% Main-path delay expressed in samples (for a discrete delay block)
N_MainDelay    = round(Delay_Seconds * Fs);

% =========================================================================
% --- 4. Source Waveforms ---
% =========================================================================
Tactical_Data   = [t, Amp_Signal     * sin(2*pi*Freq_Signal     * t)];
Interferer_Data = [t, Amp_Interferer * sin(2*pi*Freq_Interferer * t)];

% =========================================================================
% --- 5. Launch model + apply the speed settings ---
% =========================================================================
model_name = 'project';
try
    open_system(model_name);

    % --- solver ---
    set_param(model_name,'SolverType','Fixed-step');
    set_param(model_name,'Solver','FixedStepDiscrete');
    set_param(model_name,'FixedStep', num2str(Ts,'%.12g'));
    set_param(model_name,'StopTime',  num2str(T_sim,'%.12g'));

    % --- logging: the usual real bottleneck ---
    set_param(model_name,'SignalLogging','off');   % no signal-logging store
    set_param(model_name,'SaveTime','off');        % don't store tout
    set_param(model_name,'SaveOutput','on');       % keep out.* you need
    set_param(model_name,'Decimation','50');       % store 1 in 50 points

    disp(['[SUCCESS] ''' model_name '.slx'' opened and configured.']);
catch ME
    warning(['[ERROR] Could not open/configure ''' model_name '.slx'': ' ME.message]);
end

% =========================================================================
% --- 6. Summary ---
% =========================================================================
fprintf('\n--- RUN SETTINGS ---\n');
fprintf('  Interferer      : %.2f MHz @ %.4f Vpk (0 dBm)\n',  Freq_Interferer/1e6, Amp_Interferer);
fprintf('  Tactical signal : %.2f MHz @ %.4f Vpk (-20 dBm)\n', Freq_Signal/1e6,     Amp_Signal);
fprintf('  Fs              : %.1f MHz  (%d samples / interferer period)\n', Fs/1e6, SPP);
fprintf('  Ts              : %.4g s\n', Ts);
fprintf('  T_sim           : %.1f ms  (%d samples per source vector)\n', T_sim*1e3, numel(t));
fprintf('  Quarter-wave arm: %.4g s  = %d samples EXACTLY\n', Td_Quarter, N_Quarter);
fprintf('  Main delay      : %.4g s  = %d samples\n', Delay_Seconds, N_MainDelay);
fprintf('\n  Q-arm block: use Integer Delay with N_Quarter (= %d), or\n', N_Quarter);
fprintf('               Transport Delay with Td_Quarter (= %.4g s).\n\n', Td_Quarter);

commandwindow;
