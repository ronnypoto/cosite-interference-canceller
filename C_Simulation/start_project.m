function booth_demo_pro
% =========================================================================
%  ACTIVE CO-SITE INTERFERENCE CANCELLATION — PRO BOOTH DEMO
%  Features: Tactical Dark Mode, Live I/Q Vector Tracking, UI Controls,
%            and Real-Time Hardware Convergence Stopwatch (~5.5 ms tuning).
% =========================================================================

% ---------------- demo configuration ----------------
freq_list = [30 40 55 70 88] * 1e6;   
Fs   = 500e6;                          
Nwin = 1000;                           
tt   = (0:Nwin-1)'/Fs;                 
Nshow = 400;                           
A_jam = 0.60;                          
A_des = 0.06;                          
target_dB = 20;
max_iter  = 800; % Increased to allow for cautious stepping

% Physical Hardware Constraint (maps iterations to real-world time)
% STM32F446RE: ADC 16-sample moving average + Math + DAC write = ~18us per loop
hw_loop_time = 18e-6;  

% ---------------- figure & UI setup ----------------
fig = figure('Name','Active RF Cancellation System — Live Digital Twin', ...
             'Color','#121212', 'MenuBar','none', 'ToolBar','none', ...
             'WindowState', 'maximized');

setappdata(fig, 'is_paused', false);
setappdata(fig, 'force_next', false);

uicontrol('Style', 'pushbutton', 'String', '⏸ Pause / Resume', ...
    'Units', 'normalized', 'Position', [0.35 0.02 0.12 0.05], ...
    'FontSize', 14, 'FontWeight', 'bold', 'BackgroundColor', '#333333', ...
    'ForegroundColor', 'w', 'Callback', @(src,event) toggle_pause(fig, src));

uicontrol('Style', 'pushbutton', 'String', '⏭ Force Next Target', ...
    'Units', 'normalized', 'Position', [0.53 0.02 0.12 0.05], ...
    'FontSize', 14, 'FontWeight', 'bold', 'BackgroundColor', '#8B0000', ...
    'ForegroundColor', 'w', 'Callback', @(src,event) force_next(fig));

tl = tiledlayout(fig, 2, 2, 'TileSpacing', 'normal', 'Padding', 'normal');
st = sgtitle(fig,'Initializing Digital Twin...', 'FontSize', 22, 'FontWeight', 'bold', 'Color', '#00FFCC');

% Panel 1: I/Q Search Trajectory
ax1 = nexttile(tl);
h_target = plot(ax1, 0, 0, 'p', 'MarkerSize', 18, 'MarkerFaceColor', '#FF3333', 'MarkerEdgeColor', 'w'); hold(ax1,'on');
h_iq     = plot(ax1, nan, nan, '-o', 'Color', '#00FFCC', 'LineWidth', 1.5, 'MarkerSize', 4, 'MarkerFaceColor', '#00FFCC');
h_cur    = plot(ax1, 0, 0, 'o', 'MarkerSize', 10, 'MarkerFaceColor', '#FFFF00', 'MarkerEdgeColor', 'k');
title(ax1, 'Algorithm State: I/Q Vector Search', 'FontWeight', 'bold', 'Color', 'w', 'FontSize', 14);
xlabel(ax1, 'In-Phase (I)', 'Color', '#CCCCCC'); ylabel(ax1, 'Quadrature (Q)', 'Color', '#CCCCCC');
legend(ax1, {'Target Null Vector', 'Search Trajectory', 'Current State'}, 'TextColor', 'w', 'Color', 'none', 'Location', 'northeast');
xlim(ax1, [-1.2 1.2]); ylim(ax1, [-1.2 1.2]); 
style_dark_axes(ax1);
xline(ax1, 0, 'Color', '#444444', 'LineWidth', 1); yline(ax1, 0, 'Color', '#444444', 'LineWidth', 1);

% Panel 2: Time Domain
ax2 = nexttile(tl);
h_in  = plot(ax2, tt(1:Nshow)*1e9, zeros(Nshow,1), 'Color', '#FF3333', 'LineWidth', 1.2); hold(ax2,'on');
h_out = plot(ax2, tt(1:Nshow)*1e9, zeros(Nshow,1), 'Color', '#00FFCC', 'LineWidth', 2);
title(ax2, 'Time Domain: Raw RF vs Cancelled Output', 'FontWeight', 'bold', 'Color', 'w', 'FontSize', 14);
xlabel(ax2, 'Time (ns)', 'Color', '#CCCCCC'); ylabel(ax2, 'Amplitude (V)', 'Color', '#CCCCCC');
legend(ax2, {'Raw Receiver Input (Interferer + Tactical)', 'Cleaned Output (Tactical Only)'}, 'TextColor', 'w', 'Color', 'none', 'Location', 'northeast');
ylim(ax2, [-0.8 0.8]); 
style_dark_axes(ax2);

% Panel 3: Live Spectrum
ax3 = nexttile(tl);
h_sin  = plot(ax3, 0, 0, 'Color', '#FF3333', 'LineWidth', 1.5); hold(ax3,'on');
h_sout = plot(ax3, 0, 0, 'Color', '#00FFCC', 'LineWidth', 2);
title(ax3, 'Frequency Spectrum: Real-Time Suppression', 'FontWeight', 'bold', 'Color', 'w', 'FontSize', 14);
xlabel(ax3, 'Frequency (MHz)', 'Color', '#CCCCCC'); ylabel(ax3, 'Power (dB)', 'Color', '#CCCCCC');
legend(ax3, {'Threat Environment', 'System Output'}, 'TextColor', 'w', 'Color', 'none', 'Location', 'northeast');
xlim(ax3, [20 100]); ylim(ax3, [-70 10]); 
style_dark_axes(ax3);

% Panel 4: Depth vs Iteration
ax4 = nexttile(tl);
h_dep = plot(ax4, nan, nan, 'Color', '#FF00FF', 'LineWidth', 2.5); hold(ax4,'on');
yline(ax4, target_dB, '--', 'Target 20 dB', 'Color', '#FFFF00', 'LineWidth', 1.5, 'LabelHorizontalAlignment', 'left');
h_txt = text(ax4, 0.95, 0.12, '', 'Units', 'normalized', 'FontSize', 28, ...
             'FontWeight', 'bold', 'Color', '#00FFCC', 'HorizontalAlignment', 'right');
title(ax4, 'Performance: Cancellation Depth', 'FontWeight', 'bold', 'Color', 'w', 'FontSize', 14);
xlabel(ax4, 'Algorithm Iteration', 'Color', '#CCCCCC'); ylabel(ax4, 'Depth (dB)', 'Color', '#CCCCCC');
xlim(ax4, [0 max_iter]); ylim(ax4, [0 50]); 
style_dark_axes(ax4);

fidx = 0;

% ================= endless booth loop =================
while ishandle(fig)
    fidx = mod(fidx, numel(freq_list)) + 1;
    f  = freq_list(fidx);
    ph = 2*pi*rand;                    
    
    target_I = cos(ph);
    target_Q = sin(ph);
    set(h_target, 'XData', target_I, 'YData', target_Q);
    
    des      = A_des * sin(2*pi*(f-1.5e6)*tt);          
    jam_main = A_jam * sin(2*pi*f*tt + ph);             
    ref_I    = sin(2*pi*f*tt);                          
    ref_Q    = cos(2*pi*f*tt);                          
    rx_in    = jam_main + des;
    P_jam_in = mean(jam_main.^2);
    
    [fx, Sin] = spec(rx_in, Fs);
    set(h_sin,  'XData', fx/1e6, 'YData', Sin);
    set(h_in,  'YData', rx_in(1:Nshow));
    
    alg = v15_init();
    depth_hist = nan(1, max_iter);
    I_hist = nan(1, max_iter);
    Q_hist = nan(1, max_iter);
    
    setappdata(fig, 'force_next', false);
    
    for it = 1:max_iter
        if ~ishandle(fig), return; end
        
        while getappdata(fig, 'is_paused') && ishandle(fig)
            pause(0.1);
        end
        if getappdata(fig, 'force_next')
            break;
        end
        
        replica = alg.I * (A_jam*ref_I) + alg.Q * (A_jam*ref_Q);
        out     = rx_in - replica;
        P_meas  = mean(out.^2) * (1 + 0.004*randn); 
        alg = v15_step(alg, P_meas);
        
        res    = jam_main - replica;
        depth  = 10*log10(P_jam_in / max(mean(res.^2), 1e-12));
        depth_hist(it) = min(depth, 50);
        I_hist(it) = alg.I;
        Q_hist(it) = alg.Q;
        
        elapsed_ms = it * hw_loop_time * 1000;
        
        if mod(it,3)==0 || alg.locked
            set(h_out, 'YData', out(1:Nshow));
            [~, Sout] = spec(out, Fs);
            set(h_sout, 'XData', fx/1e6, 'YData', Sout);
            
            set(h_dep, 'XData', 1:it, 'YData', depth_hist(1:it));
            set(h_txt, 'String', sprintf('%.1f dB', depth_hist(it)));
            
            set(h_iq, 'XData', I_hist(1:it), 'YData', Q_hist(1:it));
            set(h_cur, 'XData', alg.I, 'YData', alg.Q);
            
            if alg.locked
                st.String = sprintf('TACTICAL BAND: %.0f MHz  |  STATUS: LOCKED (%.1f dB)  |  TIME TO LOCK: %.2f ms', f/1e6, depth_hist(it), elapsed_ms);
                st.Color = '#00FF00';
            else
                st.String = sprintf('TACTICAL BAND: %.0f MHz  |  STATUS: ACQUIRING NULL... (%.2f ms)', f/1e6, elapsed_ms);
                st.Color = '#FFCC00';
            end
            drawnow limitrate;
        end
        
        if alg.locked, break; end
    end
    
    drawnow;
    
    tEnd = tic;
    while ishandle(fig) && toc(tEnd) < 4 && ~getappdata(fig, 'force_next')
        pause(0.1);
    end
end
end

% ======================= UI Callbacks =======================
function toggle_pause(fig, btn)
    is_p = getappdata(fig, 'is_paused');
    setappdata(fig, 'is_paused', ~is_p);
    if ~is_p
        btn.String = '▶ Resume';
        btn.BackgroundColor = '#006600';
    else
        btn.String = '⏸ Pause';
        btn.BackgroundColor = '#333333';
    end
end

function force_next(fig)
    setappdata(fig, 'force_next', true);
    setappdata(fig, 'is_paused', false); 
end

function style_dark_axes(ax)
    set(ax, 'Color', '#1E1E1E', 'XColor', '#888888', 'YColor', '#888888', ...
        'GridColor', '#555555', 'GridAlpha', 0.5, 'MinorGridColor', '#333333');
    grid(ax, 'on');
end

% ======================= V15 ALGORITHM =======================
function a = v15_init()
a.I=0; a.Q=0; a.Step=0.20; a.Dir=1; a.Last=1e12; a.Stall=0;
a.BestI=0; a.BestQ=0; a.locked=false; a.phase=1; a.Init=-1;
a.Streak=0; a.Kicked=false; a.LSB=0.0005;
end

function a = v15_step(a, P)
if a.Init < 0, a.Init = max(P,1e-12); end       
if a.locked, return; end

Tgt = a.LSB;
if a.phase == 1
    Tgt = 0.20 * sqrt(P / a.Init);
    Tgt = min(max(Tgt, a.LSB), 0.25);
end
if P < a.Last * 0.999
    a.Last = P; a.Stall = 0; a.Kicked = false;
    a.BestI = a.I; a.BestQ = a.Q;
    a.Streak = a.Streak + 1;
    if a.phase == 1
        a.Step = Tgt;
        % SLOWED DOWN: Momentum multiplier reduced to stretch the search
        if a.Streak >= 2, a.Step = min(a.Step*1.5, 0.25); end 
    else
        % SLOWED DOWN: Cautious gradient descent in phase 2
        if a.Streak >= 2, a.Step = min(a.Step*1.4, 0.05);
        else,             a.Step = min(a.Step*1.1, 0.05); end 
    end
else
    a.Streak = 0;
    [dI,dQ] = dirvec(a.Dir);
    a.I = a.I - a.Step*dI;  a.Q = a.Q - a.Step*dQ;
    a.Dir = a.Dir + 1;
    if a.Dir > 8
        a.Dir = 1; a.Stall = a.Stall + 1;
        a.I = a.BestI; a.Q = a.BestQ;
        if a.phase == 1
            a.Step = max(a.Step*0.6, Tgt); % Less drastic cut
            if a.Stall >= 3
                if a.Last < 0.25 * a.Init
                    a.phase = 2; a.Stall = 0; a.Kicked = false;
                else
                    a.Step = 0.20; a.Stall = 0;
                end
            end
        else
            a.Step = max(a.Step*0.6, a.LSB);
            if a.Stall == 4 && ~a.Kicked
                a.Step = min(max(a.Step*5, 0.01), 0.04);
                a.Kicked = true;
            end
            % SLOWED DOWN: Force the algorithm to check more directions before declaring lock
            if a.Stall >= 12 && a.Step <= 1.5*a.LSB 
                a.locked = true;
                a.I = a.BestI; a.Q = a.BestQ;
                return;
            end
        end
    end
end
[dI,dQ] = dirvec(a.Dir);
a.I = min(max(a.I + a.Step*dI, -1), 1);
a.Q = min(max(a.Q + a.Step*dQ, -1), 1);
end

function [dI,dQ] = dirvec(d)
switch d
    case 1, dI= 1; dQ= 0;
    case 2, dI=-1; dQ= 0;
    case 3, dI= 0; dQ= 1;
    case 4, dI= 0; dQ=-1;
    case 5, dI= 1; dQ= 1;
    case 6, dI= 1; dQ=-1;
    case 7, dI=-1; dQ= 1;
    otherwise, dI=-1; dQ=-1;
end
end

function [fx, SdB] = spec(x, Fs)
L  = length(x);
w  = hann(L);
Y  = abs(fft(x .* w) / (L/4));
P1 = Y(1:floor(L/2)+1);
fx = Fs * (0:floor(L/2))' / L;
SdB = 20*log10(P1 + 1e-6);
end