function NeuroScope2(varargin)
% % % % % % % % % % % % % % % % % % % % % % % % %
% NeuroScope2 is a visualizer for electrophysiological recordings. It was inspired by the original Neuroscope (http://neurosuite.sourceforge.net/)
% and made to mimic its features, but built upon Matlab and the data structure of CellExplorer, making it much easier to hack/customize, 
% and faster than the original NeuroScope. NeuroScope2 is part of CellExplorer - https://CellExplorer.org/
% Learn more at: https://cellexplorer.org/interface/neuroscope2/
%
% Major features:
% - Multiple plotting styles and colors, electrode groups, channel tags, highlight, filter and hide channels
% - Live trace analysis: filters, spike and event detection, single channel spectrogram, RMS-noise-plot, CSD and spike waveforms
% - Plot multiple data streams together (ephys + analog + digital signals)
% - Plot CellExplorer/Buzcode structures: spikes, cell metrics, events, timeseries, states, behavior, trials
%
% Example calls:
%    NeuroScope2
%    NeuroScope2('basepath',basepath)
%    NeuroScope2('session',session)
%
% By Peter Petersen
% % % % % % % % % % % % % % % % % % % % % % % % %

% Shortcuts to built-in functions
% initUI, initData, initInputs, initTraces, 
% ClickPlot, performTestSuite
% plotData, plot_ephys, plotSpikeData, plotSpectrogram, plotTemporalStates, plotEventData, plotTimeseriesData, streamData
% plotAnalog, plotDigital, plotBehavior, plotTrials, plotRMSnoiseInset, plotSpikesPCAspace
% showEvents, showBehavior

% Global variables
UI = []; % Struct with UI elements and settings
UI.t0 = 0; % Timestamp of the start of the current window (in seconds)
data = []; % Contains all external data loaded like data.session, data.spikes, data.events, data.states, data.behavior
ephys = []; % Struct with ephys data for current shown time interval, e.g. ephys.raw (raw unprocessed data), ephys.traces (processed data)
ephys.traces = [];
ephys.sr = [];
UI.selectedUnits = [];            
UI.selectedUnitsColors = [];
            
spikes_raster = []; % Spike raster (used for highlighting, to minimize computations)
epoch_plotElements.t0 = [];
epoch_plotElements.events = [];
raster = [];
sliderMovedManually = false;
deviceWriter = [];
polygon1.handle = gobjects(0);

if isdeployed % Check for if NeuroScope2 is running as a deployed app (compiled .exe or .app for windows and mac respectively)
    if ~isempty(varargin) % If a file name is provided it will load it.
        [basepath,basename,ext] = fileparts(varargin{1});
        if isequal(basepath,0)
            UI.priority = ext;
            return
        end
    else % Otherwise a file load dialog will be shown
        [file1,basepath] = uigetfile('*.mat;*.dat;*.lfp;*.xml','Please select a file with the basename in it from the basepath');
        if ~isequal(file1,0)
            temp1 = strsplit(file1,'.');
            basename = temp1{1};
            UI.priority = temp1{2};
        else
            return
        end
    end
else
    % Handling inputs if run from Matlab
    p = inputParser;
    addParameter(p,'basepath',pwd,@ischar);
    addParameter(p,'basename',[],@ischar);
    addParameter(p,'session',[],@isstruct);
    addParameter(p,'spikes',[],@ischar);
    addParameter(p,'events',[],@ischar);
    addParameter(p,'states',[],@ischar);
    addParameter(p,'behavior',[],@ischar);
    addParameter(p,'cellinfo',[],@ischar);
    addParameter(p,'channeltag',[],@ischar);
    addParameter(p,'performTestSuite',false,@islogical);
    parse(p,varargin{:})
    parameters = p.Results;
    basepath = p.Results.basepath;
    basename = p.Results.basename;
    if isempty(basename)
        basename = basenameFromBasepath(basepath);
    end
    if ~isempty(parameters.session)
        basename = parameters.session.general.name;
        basepath = parameters.session.general.basePath;
    end
end

int_gt_0 = @(n,sr) (isempty(n)) || (n <= 0 ) || (n >= sr/2) || isnan(n);

% % % % % % % % % % % % % % % % % % % % % %
% Initialization 
% % % % % % % % % % % % % % % % % % % % % %

initUI
initData(basepath,basename);
initInputs
initTraces

if UI.settings.audioPlay
    initAudioDeviceWriter
end

% Maximazing figure to full screen
if ~verLessThan('matlab', '9.4')
    set(UI.fig,'WindowState','maximize'), set(UI.fig,'visible','on')
else
    warning('off','MATLAB:HandleGraphics:ObsoletedProperty:JavaFrame')
    set(UI.fig,'visible','on')
    drawnow nocallbacks; frame_h = get(UI.fig,'JavaFrame'); set(frame_h,'Maximized',1); drawnow nocallbacks;
end

% Perform test suite by input parameter
if exist('parameters','var') && parameters.performTestSuite
    UI.settings.allow_dialogs = false;
    performTestSuite
    UI.t0 = -1;
end

% % % % % % % % % % % % % % % % % % % % % %
% Main while loop of the interface
% % % % % % % % % % % % % % % % % % % % % %

while UI.t0 >= 0
    % breaking if figure has been closed
    if ~ishandle(UI.fig)
        break
    else
        if ~UI.settings.stickySelection
            UI.selectedChannels = [];
            UI.selectedChannelsColors = [];
            
            UI.selectedUnits = [];            
            UI.selectedUnitsColors = [];
        end
        
        % Plotting data
        plotData;
        
        if UI.t0 == UI.t_total-UI.settings.windowDuration
            UI.streamingText = text(UI.plot_axis1,UI.settings.windowDuration/2,1,'End of file','FontWeight', 'Bold','VerticalAlignment', 'top','HorizontalAlignment','center','color',UI.settings.primaryColor,'HitTest','off');
        end        
        
        % Updating epoch axes
        if ishandle(epoch_plotElements.t0)
            delete(epoch_plotElements.t0)
        end
        epoch_plotElements.t0 = line(UI.epochAxes,[UI.t0,UI.t0],[0,1],'color','k', 'HitTest','off','linewidth',1);
        
        % Update UI text and slider
        UI.elements.lower.time.String = num2str(UI.t0);
        setTimeText(UI.t0)
        
        sliderMovedManually = false;
        UI.elements.lower.slider.Value = min([UI.t0/(UI.t_total-UI.settings.windowDuration)*100,100]);
        if UI.settings.debug
            drawnow
        end
        UI.elements.lower.performance.String = ['  Processing: ' num2str(toc(UI.timerInterface),3) ' seconds (', num2str(numel(ephys.traces)*2/1024/1024,3) ' MB ephys data)'];
        uiwait(UI.fig);
        
        % Tracking viewed timestamps in file (the history can be used by pressing the backspace key)
        UI.settings.stream = false;
        UI.t0 = max([0,min([UI.t0,UI.t_total-UI.settings.windowDuration])]);
        if UI.track && UI.t0_track(end) ~= UI.t0
            UI.t0_track = [UI.t0_track,UI.t0];
        end
        UI.track = true;
    end
    UI.timerInterface = tic;
end

% % % % % % % % % % % % % % % % % % % % % %
% Closing 
% % % % % % % % % % % % % % % % % % % % % %

% Closing all file readers
fclose('all');

% Closing main figure if open
if ishandle(UI.fig)
    close(UI.fig);
end

% Using google analytics for anonymous tracking of usage
trackGoogleAnalytics('NeuroScope2',1); 

% Saving session metadata
if UI.settings.saveMetadata
    session = data.session;
    session.neuroScope2.t0 = UI.t0;
    session.neuroScope2.colors = UI.colors;
    for i_setting = 1:length(UI.settings.to_save)
        session.neuroScope2.(UI.settings.to_save{i_setting}) =  UI.settings.(UI.settings.to_save{i_setting});
    end

    try
        saveStruct(session,'session','commandDisp',false);
    catch
        warning('Could not save session struct to basepath when closing NeuroScope2')
    end
end

% % % % % % % % % % % % % % % % % % % % % %
% Embedded functions 
% % % % % % % % % % % % % % % % % % % % % %

    function initUI % Initialize the UI (settings, parameters, figure, menu, panels, axis)
        
        % % % % % % % % % % % % % % % % % % % % % %
        % System settings
        % % % % % % % % % % % % % % % % % % % % % %
        
        UI.forceNewData = true; % Reload raw data on display
        UI.timerInterface = tic;
        UI.timers.slider = tic;
        UI.iLine = 1;
        UI.colorLine = lines(256);
        UI.freeText = '';
        UI.selectedChannels = [];
        UI.selectedChannelsColors = [];
        UI.legend = {};
        UI.settings.saveMetadata = true; % Save metadata on exit
        UI.settings.fileRead = 'bof';
        UI.settings.channelList = [];
        UI.settings.brainRegionsToHide = [];
        UI.settings.channelTags.hide = [];
        UI.settings.channelTags.filter = [];
        UI.settings.channelTags.highlight = [];
        UI.settings.normalClick = true;
        UI.settings.addEventonClick = 0;
        UI.settings.columns = 1;
        UI.settings.allow_dialogs = true;
        
        % Spikes settings
        UI.settings.showSpikes = false;
        
        UI.settings.showKilosort = false;
        UI.settings.showKlusta = false;
        UI.settings.showSpykingcircus = false;
        UI.settings.reverseSpikeSorting = 'ascend'; % 'ascend' or 'descend'
        
        % Cell metrics
        UI.settings.useMetrics = false;
        
        % Event settings
        UI.settings.showEvents = false;
        UI.settings.eventData = [];
        
        % Timeseries settings
        UI.settings.showTimeseries = false;
        UI.settings.timeseriesData = [];
        
        % States settings
        UI.settings.showStates = false;
        UI.settings.statesData = [];
        
        % Behavior settings
        UI.settings.showBehavior = false;
        UI.settings.behaviorData = [];
        
        % Intan settings
        UI.settings.intan_showAnalog = false;
        UI.settings.intan_showAux = false;
        UI.settings.intan_showDigital = false;
        
        % Cell metrics
        UI.params.cellTypes = [];
        UI.params.cell_class_count = [];
        UI.groupData1.groupsList = {'groups','tags','groundTruthClassification'};        
        UI.tableData.Column1 = 'putativeCellType';
        UI.tableData.Column2 = 'firingRate';
        UI.params.subsetTable = [];
        UI.params.subsetFilter = [];
        UI.params.subsetCellType = [];
        UI.params.subsetGroups = [];
        UI.params.sortingMetric = 'putativeCellType';
        UI.params.groupMetric = 'putativeCellType';
        
        % Audio
        preferences.audioPlay = false; % Can be true or false
        UI.settings.playAudioFirst = false; % Must be false
        UI.settings.deviceWriterActive = false; % Must be false
        
        % % % % % % % % % % % % % % % % % % % % % %
        % User preferences/settings
        % % % % % % % % % % % % % % % % % % % % % %
        
        UI.settings = preferences_NeuroScope2(UI.settings);        
        
        % % % % % % % % % % % % % % % % % % % % % %
        % Creating figure
        % % % % % % % % % % % % % % % % % % % % % %
        
        UI.fig = figure('Name','NeuroScope2','NumberTitle','off','renderer','opengl','KeyPressFcn', @keyPress,'KeyReleaseFcn',@keyRelease,'DefaultAxesLooseInset',[.01,.01,.01,.01],'visible','off','pos',[0,0,1600,800],'DefaultTextInterpreter', 'none', 'DefaultLegendInterpreter', 'none', 'MenuBar', 'None');
        if ~verLessThan('matlab', '9.3')
            menuLabel = 'Text';
            menuSelectedFcn = 'MenuSelectedFcn';
        else
            menuLabel = 'Label';
            menuSelectedFcn = 'Callback';
        end
        uix.tracking('off')
        
        % % % % % % % % % % % % % % % % % % % % % %
        % Creating menu
        
        % NeuroScope2
        UI.menu.cellExplorer.topMenu = uimenu(UI.fig,menuLabel,'NeuroScope2');
        uimenu(UI.menu.cellExplorer.topMenu,menuLabel,'About NeuroScope2',menuSelectedFcn,@AboutDialog);
        uimenu(UI.menu.cellExplorer.topMenu,menuLabel,'Benchmark NeuroScope2',menuSelectedFcn,@benchmarkStream);
        uimenu(UI.menu.cellExplorer.topMenu,menuLabel,'Perform test suite of NeuroScope2',menuSelectedFcn,@performTestSuite);
        uimenu(UI.menu.cellExplorer.topMenu,menuLabel,'Quit',menuSelectedFcn,@exitNeuroScope2,'Separator','on','Accelerator','W');
        
        % File
        UI.menu.file.topMenu = uimenu(UI.fig,menuLabel,'File');
        uimenu(UI.menu.file.topMenu,menuLabel,'Load session from folder',menuSelectedFcn,@loadFromFolder);
        uimenu(UI.menu.file.topMenu,menuLabel,'Load session from file',menuSelectedFcn,@loadFromFile,'Accelerator','O');
        UI.menu.file.recentSessions.main = uimenu(UI.menu.file.topMenu,menuLabel,'Recent sessions...','Separator','on');
        uimenu(UI.menu.file.topMenu,menuLabel,'Export figure data...',menuSelectedFcn,@exportPlotData,'Separator','on');
        uimenu(UI.menu.file.topMenu,menuLabel,'Create video...',menuSelectedFcn,@createVideo,'Separator','on');
        
        % Session
        UI.menu.session.topMenu = uimenu(UI.fig,menuLabel,'Session');
        uimenu(UI.menu.session.topMenu,menuLabel,'View metadata',menuSelectedFcn,@viewSessionMetaData);
        uimenu(UI.menu.session.topMenu,menuLabel,'Save metadata',menuSelectedFcn,@saveSessionMetadata);
        uimenu(UI.menu.session.topMenu,menuLabel,'Open basepath',menuSelectedFcn,@openSessionDirectory,'Separator','on');
        
        % Cell metrics 
        UI.menu.cellExplorer.topMenu = uimenu(UI.fig,menuLabel,'Cell metrics');
        UI.menu.cellExplorer.defineGroupData = uimenu(UI.menu.cellExplorer.topMenu,menuLabel,'Open group data dialog',menuSelectedFcn,@defineGroupData);
        UI.menu.cellExplorer.saveCellMetrics = uimenu(UI.menu.cellExplorer.topMenu,menuLabel,'Save cell_metrics',menuSelectedFcn,@saveCellMetrics);
        uimenu(UI.menu.cellExplorer.topMenu,menuLabel,'Open CellExplorer',menuSelectedFcn,@openCellExplorer);
        
        % Settings
        UI.menu.display.topMenu = uimenu(UI.fig,menuLabel,'Settings');
        UI.menu.display.ShowHideMenu = uimenu(UI.menu.display.topMenu,menuLabel,'Show full menu',menuSelectedFcn,@ShowHideMenu);
        UI.menu.display.removeDC = uimenu(UI.menu.display.topMenu,menuLabel,'Remove DC from ephys traces',menuSelectedFcn,@removeDC,'Separator','on');
        UI.menu.display.medianFilter = uimenu(UI.menu.display.topMenu,menuLabel,'Apply median filter to ephys traces',menuSelectedFcn,@medianFilter);
        UI.menu.display.plotTracesInColumns = uimenu(UI.menu.display.topMenu,menuLabel,'Multiple columns',menuSelectedFcn,@columnTraces,'Separator','on');
        UI.menu.display.plotStyleDynamicRange = uimenu(UI.menu.display.topMenu,menuLabel,'Dynamic ephys range plot',menuSelectedFcn,@plotStyleDynamicRange,'Checked','on');
        UI.menu.display.narrowPadding = uimenu(UI.menu.display.topMenu,menuLabel,'Narrow ephys padding',menuSelectedFcn,@narrowPadding);
        UI.menu.display.resetZoomOnNavigation = uimenu(UI.menu.display.topMenu,menuLabel,'Reset zoom on navigation',menuSelectedFcn,@resetZoomOnNavigation);
        UI.menu.display.showScalebar = uimenu(UI.menu.display.topMenu,menuLabel,'Show vertical scale bar',menuSelectedFcn,@showScalebar);
        UI.menu.display.showTimeScalebar = uimenu(UI.menu.display.topMenu,menuLabel,'Show time scale bar',menuSelectedFcn,@showTimeScalebar);
        UI.menu.display.showChannelNumbers = uimenu(UI.menu.display.topMenu,menuLabel,'Show channel numbers',menuSelectedFcn,@ShowChannelNumbers);  
        UI.menu.display.stickySelection = uimenu(UI.menu.display.topMenu,menuLabel,'Sticky selection of channels',menuSelectedFcn,@setStickySelection);
       
        UI.menu.display.channelOrder.topMenu = uimenu(UI.menu.display.topMenu,menuLabel,'Channel order','Separator','on');
        UI.menu.display.channelOrder.option(1) = uimenu(UI.menu.display.channelOrder.topMenu,menuLabel,'Electrode groups',menuSelectedFcn,@setChannelOrder);
        UI.menu.display.channelOrder.option(2) = uimenu(UI.menu.display.channelOrder.topMenu,menuLabel,'Flipped electrode groups',menuSelectedFcn,@setChannelOrder);
        UI.menu.display.channelOrder.option(3) = uimenu(UI.menu.display.channelOrder.topMenu,menuLabel,'Ascending channel order',menuSelectedFcn,@setChannelOrder);
        UI.menu.display.channelOrder.option(4) = uimenu(UI.menu.display.channelOrder.topMenu,menuLabel,'Descending channel order',menuSelectedFcn,@setChannelOrder);
        UI.menu.display.channelOrder.option(UI.settings.channelOrder).Checked = 'on';
        
        UI.menu.display.colorgroups.topMenu = uimenu(UI.menu.display.topMenu,menuLabel,'Color groups');
        UI.menu.display.colorgroups.option(1) = uimenu(UI.menu.display.colorgroups.topMenu,menuLabel,'By electrode groups',menuSelectedFcn,@setColorGroups);
        UI.menu.display.colorgroups.option(2) = uimenu(UI.menu.display.colorgroups.topMenu,menuLabel,'By channel order',menuSelectedFcn,@setColorGroups);
        UI.menu.display.colorgroups.option(3) = uimenu(UI.menu.display.colorgroups.topMenu,menuLabel,'By custom-sized channel groups',menuSelectedFcn,@setColorGroups);
        UI.menu.display.colorgroups.option(UI.settings.colorByChannels).Checked = 'on';
        
        
        UI.menu.display.colormap = uimenu(UI.menu.display.topMenu,menuLabel,'Color maps');
        UI.menu.display.changeColormap = uimenu(UI.menu.display.colormap,menuLabel,'Change colormap of ephys traces',menuSelectedFcn,@changeColormap);
        UI.menu.display.changeSpikesColormap = uimenu(UI.menu.display.colormap,menuLabel,'Change colormap of spikes',menuSelectedFcn,@changeSpikesColormap);        
        UI.menu.display.changeBackgroundColor = uimenu(UI.menu.display.colormap,menuLabel,'Change background color & primary color',menuSelectedFcn,@changeBackgroundColor);

        UI.menu.display.colormap = uimenu(UI.menu.display.topMenu,menuLabel,'Trace parameters');
        UI.menu.display.changeLinewidth = uimenu(UI.menu.display.colormap,menuLabel,'Change linewidth of ephys traces',menuSelectedFcn,@changeLinewidth);
        
        UI.menu.display.detectedSpikes = uimenu(UI.menu.display.topMenu,menuLabel,'Detected spikes','Separator','on');
        UI.menu.display.detectedSpikesBelowTrace = uimenu(UI.menu.display.detectedSpikes,menuLabel,'Show below traces',menuSelectedFcn,@detectedSpikesBelowTrace);
        UI.menu.display.spikesDetectionPolarity = uimenu(UI.menu.display.detectedSpikes,menuLabel,'Detect both polarities',menuSelectedFcn,@detectedSpikesPolarity);
        UI.menu.display.showDetectedSpikesPopulationRate = uimenu(UI.menu.display.detectedSpikes,menuLabel,'Show population rate',menuSelectedFcn,@showDetectedSpikesPopulationRate);
        UI.menu.display.showDetectedSpikeWaveforms = uimenu(UI.menu.display.detectedSpikes,menuLabel,'Show waveforms',menuSelectedFcn,@showDetectedSpikeWaveforms);
        UI.menu.display.colorDetectedSpikesByWidth = uimenu(UI.menu.display.detectedSpikes,menuLabel,'Color by waveform width',menuSelectedFcn,@toggleColorDetectedSpikesByWidth);
        UI.menu.display.showDetectedSpikesPCAspace = uimenu(UI.menu.display.detectedSpikes,menuLabel,'Show PCA space (beta feature)',menuSelectedFcn,@showDetectedSpikesPCAspace);
        UI.menu.display.showDetectedSpikesAmplitudeDistribution = uimenu(UI.menu.display.detectedSpikes,menuLabel,'Show spike amplitude distribution',menuSelectedFcn,@showDetectedSpikesAmplitudeDistribution);
        UI.menu.display.showDetectedSpikesCountAcrossChannels = uimenu(UI.menu.display.detectedSpikes,menuLabel,'Show count across channels',menuSelectedFcn,@showDetectedSpikesCountAcrossChannels);
        
        UI.menu.display.detectedEvents = uimenu(UI.menu.display.topMenu,menuLabel,'Detected events');
        UI.menu.display.detectedEventsBelowTrace = uimenu(UI.menu.display.detectedEvents,menuLabel,'Show below traces',menuSelectedFcn,@detectedEventsBelowTrace);

        UI.menu.display.debug = uimenu(UI.menu.display.topMenu,menuLabel,'Debug','Separator','on',menuSelectedFcn,@toggleDebug);
        
        % Analysis
        UI.menu.analysis.topMenu = uimenu(UI.fig,menuLabel,'Analysis');
        try
            initAnalysisToolsMenu
        end
        UI.menu.analysis.summaryFigure = uimenu(UI.menu.analysis.topMenu,menuLabel,'Summary figure',menuSelectedFcn,@summaryFigure,'Separator','on');
        
        % BuzLabDB
        if db_is_active
            UI.menu.BuzLabDB.topMenu = uimenu(UI.fig,menuLabel,'BuzLabDB');
            uimenu(UI.menu.BuzLabDB.topMenu,menuLabel,'Load session from BuzLabDB',menuSelectedFcn,@DatabaseSessionDialog,'Accelerator','D');
            uimenu(UI.menu.BuzLabDB.topMenu,menuLabel,'Edit credentials',menuSelectedFcn,@editDBcredentials,'Separator','on');
            uimenu(UI.menu.BuzLabDB.topMenu,menuLabel,'Edit repository paths',menuSelectedFcn,@editDBrepositories);
            uimenu(UI.menu.BuzLabDB.topMenu,menuLabel,'View current session on website',menuSelectedFcn,@openSessionInWebDB,'Separator','on');
            uimenu(UI.menu.BuzLabDB.topMenu,menuLabel,'View current animal subject on website',menuSelectedFcn,@showAnimalInWebDB);
        end
        
        % Help
        UI.menu.help.topMenu = uimenu(UI.fig,menuLabel,'Help');
        uimenu(UI.menu.help.topMenu,menuLabel,'Mouse and keyboard shortcuts',menuSelectedFcn,@HelpDialog);
        uimenu(UI.menu.help.topMenu,menuLabel,'CellExplorer website',menuSelectedFcn,@openWebsite,'Separator','on');
        uimenu(UI.menu.help.topMenu,menuLabel,'- About NeuroScope2',menuSelectedFcn,@openWebsite);
        uimenu(UI.menu.help.topMenu,menuLabel,'- Tutorial on metadata',menuSelectedFcn,@openWebsite);
        uimenu(UI.menu.help.topMenu,menuLabel,'- Documentation on session metadata',menuSelectedFcn,@openWebsite);
        uimenu(UI.menu.help.topMenu,menuLabel,'Support',menuSelectedFcn,@openWebsite,'Separator','on');
        uimenu(UI.menu.help.topMenu,menuLabel,'- Submit feature request',menuSelectedFcn,@openWebsite);
        uimenu(UI.menu.help.topMenu,menuLabel,'- Report an issue',menuSelectedFcn,@openWebsite);

        % % % % % % % % % % % % % % % % % % % % % %
        % Creating UI/panels 
        
        UI.grid_panels = uix.GridFlex( 'Parent', UI.fig, 'Spacing', 5, 'Padding', 0); % Flexib grid box
        UI.panel.left = uix.VBoxFlex('Parent',UI.grid_panels,'position',[0 0.66 0.26 0.31]); % Left panel
        
        UI.panel.center = uix.VBox( 'Parent', UI.grid_panels, 'Spacing', 0, 'Padding', 0 ); % Center flex box
        % UI.panel.right = uix.VBoxFlex('Parent',UI.grid_panels,'position',[0 0.66 0.26 0.31]); % Right panel
        set(UI.grid_panels, 'Widths', [270 -1],'MinimumWidths',[220 1]); % set grid panel size
        set(UI.grid_panels, 'Widths', [270 -1],'MinimumWidths',[5 1]); % set grid panel size
        % Separation of the center box into three panels: title panel, plot panel and lower info panel
        UI.panel.plots = uipanel('position',[0 0 1 1],'BorderType','none','Parent',UI.panel.center,'BackgroundColor','k'); % Main plot panel
        UI.panel.info  = uix.HBox('Parent',UI.panel.center, 'Padding', 1); % Lower info panel
        set(UI.panel.center, 'Heights', [-1 20]); % set center panel size
        
        % Left panel tabs
        UI.uitabgroup = uiextras.TabPanel('Parent', UI.panel.left, 'Padding', 1,'FontSize',UI.settings.fontsize ,'TabSize',50);
        UI.panel.general.main1  = uix.ScrollingPanel('Parent',UI.uitabgroup, 'Padding', 0 );
        UI.panel.general.main  = uix.VBox('Parent',UI.panel.general.main1, 'Padding', 1);
        UI.panel.spikedata.main1  = uix.ScrollingPanel('Parent',UI.uitabgroup, 'Padding', 0 );
        UI.panel.spikedata.main  = uix.VBox('Parent',UI.panel.spikedata.main1, 'Padding', 1);
        UI.panel.other.main1  = uix.ScrollingPanel('Parent',UI.uitabgroup, 'Padding', 0 );
        UI.panel.other.main  = uix.VBox('Parent',UI.panel.other.main1, 'Padding', 1);
        UI.panel.analysis.main1  = uix.ScrollingPanel('Parent',UI.uitabgroup, 'Padding', 0 );
        UI.panel.analysis.main  = uix.VBox('Parent',UI.panel.analysis.main1, 'Padding', 1);
        UI.uitabgroup.TabNames = {'General', 'Spikes','Other','Analysis'};

        % % % % % % % % % % % % % % % % % % % % % %
        % 1. PANEL: General elements
        % Navigation
        UI.panel.general.navigation = uipanel('Parent',UI.panel.general.main,'title','Navigation');
        UI.buttons.play1 = uicontrol('Parent',UI.panel.general.navigation,'Style','pushbutton','Units','normalized','Position',[0.01 0.01 0.15 0.98],'String',char(9654),'Callback',@(~,~)streamDataButtons,'KeyPressFcn', @keyPress,'tooltip','Stream from current timepoint'); 
        uicontrol('Parent',UI.panel.general.navigation,'Style','pushbutton','Units','normalized','Position',[0.17 0.01 0.15 0.98],'String',char(8592),'Callback',@(src,evnt)back,'KeyPressFcn', @keyPress,'tooltip','Go back in time');
        uicontrol('Parent',UI.panel.general.navigation,'Style','pushbutton','Units','normalized','Position',[0.33 0.5 0.34 0.49],'String',char(8593),'Callback',@(src,evnt)increaseAmplitude,'KeyPressFcn', @keyPress,'tooltip','Increase amplitude of ephys data');
        uicontrol('Parent',UI.panel.general.navigation,'Style','pushbutton','Units','normalized','Position',[0.33 0.01 0.34 0.49],'String',char(8595),'Callback',@(src,evnt)decreaseAmplitude,'KeyPressFcn', @keyPress,'tooltip','Decrease amplitude of ephys data');
        uicontrol('Parent',UI.panel.general.navigation,'Style','pushbutton','Units','normalized','Position',[0.68 0.01 0.15 0.98],'String',char(8594),'Callback',@(src,evnt)advance,'KeyPressFcn', @keyPress,'tooltip','Forward in time');
        UI.buttons.play2 = uicontrol('Parent',UI.panel.general.navigation,'Style','pushbutton','Units','normalized','Position',[0.84 0.01 0.15 0.98],'String',[char(9655) char(9654)],'Callback',@(~,~)streamDataButtons2,'KeyPressFcn', @keyPress,'tooltip','Stream from end of file');
        
        % Electrophysiology
        UI.panel.general.filter = uipanel('Parent',UI.panel.general.main,'title','Extracellular traces');
        uicontrol('Parent',UI.panel.general.filter,'Style', 'text', 'String', 'Plot style', 'Units','normalized', 'Position', [0.01 0.87 0.3 0.1],'HorizontalAlignment','left','tooltip','Select plot style');
        uicontrol('Parent',UI.panel.general.filter,'Style', 'text', 'String', 'Plot colors', 'Units','normalized', 'Position', [0.01 0.74 0.3 0.1],'HorizontalAlignment','left','tooltip','Select plot colors/greyscale');
        UI.panel.general.plotStyle = uicontrol('Parent',UI.panel.general.filter,'Style', 'popup','String',{'Downsampled','Range','Raw','LFP (*.lfp file)','Image','No ephys traces'}, 'value', UI.settings.plotStyle, 'Units','normalized', 'Position', [0.3 0.86 0.69 0.12],'Callback',@changePlotStyle,'HorizontalAlignment','left');
        UI.panel.general.colorScale = uicontrol('Parent',UI.panel.general.filter,'Style', 'popup','String',{'Colors','Colors 75%','Colors 50%','Colors 25%','Grey-scale','Grey-scale 75%','Grey-scale 50%','Grey-scale 25%'}, 'value', 1, 'Units','normalized', 'Position', [0.3 0.73 0.69 0.12],'Callback',@changeColorScale,'HorizontalAlignment','left');
        UI.panel.general.filterToggle = uicontrol('Parent',UI.panel.general.filter,'Style', 'checkbox','String','Filter traces', 'value', 0, 'Units','normalized', 'Position', [0. 0.62 0.5 0.11],'Callback',@changeTraceFilter,'HorizontalAlignment','left','tooltip','Filter ephys traces');
        UI.panel.general.extraSpacing = uicontrol('Parent',UI.panel.general.filter,'Style', 'checkbox','String','Group spacing', 'value', 0, 'Units','normalized', 'Position', [0.5 0.62 0.5 0.11],'Callback',@extraSpacing,'HorizontalAlignment','left','tooltip','Spacing between channels from different electrode groups');
        if UI.settings.extraSpacing
            UI.panel.general.extraSpacing.Value = 1;
        end
        uicontrol('Parent',UI.panel.general.filter,'Style', 'text', 'String', 'Lower filter (Hz)', 'Units','normalized', 'Position', [0.0 0.52 0.5 0.09],'HorizontalAlignment','center');
        uicontrol('Parent',UI.panel.general.filter,'Style', 'text', 'String', 'Higher filter (Hz)', 'Units','normalized', 'Position', [0.5 0.52 0.5 0.09],'HorizontalAlignment','center');
        UI.panel.general.lowerBand  = uicontrol('Parent',UI.panel.general.filter,'Style', 'Edit', 'String', '400', 'Units','normalized', 'Position', [0.01 0.39 0.48 0.12],'Callback',@changeTraceFilter,'HorizontalAlignment','center','tooltip','Lower frequency boundary (Hz)');
        UI.panel.general.higherBand = uicontrol('Parent',UI.panel.general.filter,'Style', 'Edit', 'String', '', 'Units','normalized', 'Position', [0.5 0.39 0.49 0.12],'Callback',@changeTraceFilter,'HorizontalAlignment','center','tooltip','Higher frequency band (Hz)');
        UI.panel.general.plotEnergy = uicontrol('Parent',UI.panel.general.filter,'Style', 'checkbox','String','Absolute smoothing (sec)', 'value', 0, 'Units','normalized', 'Position', [0.01 0.26 0.68 0.12],'Callback',@plotEnergy,'HorizontalAlignment','left');
        UI.panel.general.energyWindow = uicontrol('Parent',UI.panel.general.filter,'Style', 'Edit', 'String', num2str(UI.settings.energyWindow), 'Units','normalized', 'Position', [0.7 0.26 0.29 0.12],'Callback',@plotEnergy,'HorizontalAlignment','center','tooltip','Smoothing window (seconds)');
        UI.panel.general.detectEvents = uicontrol('Parent',UI.panel.general.filter,'Style', 'checkbox','String',['Detect events (',char(181),'V)'], 'value', 0, 'Units','normalized', 'Position', [0.01 0.135 0.68 0.12],'Callback',@toogleDetectEvents,'HorizontalAlignment','left');
        UI.panel.general.eventThreshold = uicontrol('Parent',UI.panel.general.filter,'Style', 'Edit', 'String', num2str(UI.settings.eventThreshold), 'Units','normalized', 'Position', [0.7 0.135 0.29 0.12],'Callback',@toogleDetectEvents,'HorizontalAlignment','center','tooltip',['Event detection threshold (',char(181),'V)']);
        UI.panel.general.detectSpikes = uicontrol('Parent',UI.panel.general.filter,'Style', 'checkbox','String',['Detect spikes (',char(181),'V)'], 'value', 0, 'Units','normalized', 'Position', [0.01 0.01 0.68 0.12],'Callback',@toogleDetectSpikes,'HorizontalAlignment','left');
        UI.panel.general.detectThreshold = uicontrol('Parent',UI.panel.general.filter,'Style', 'Edit', 'String', num2str(UI.settings.spikesDetectionThreshold), 'Units','normalized', 'Position', [0.7 0.01 0.29 0.12],'Callback',@toogleDetectSpikes,'HorizontalAlignment','center','tooltip',['Spike detection threshold (',char(181),'V)']);
        
        % Electrode groups
        UI.uitabgroup_channels = uiextras.TabPanel('Parent', UI.panel.general.main, 'Padding', 1,'FontSize',UI.settings.fontsize ,'TabSize',50);
        UI.panel.electrodeGroups.main  = uix.VBox('Parent',UI.uitabgroup_channels, 'Padding', 1);
        UI.panel.chanelList.main  = uix.VBox('Parent',UI.uitabgroup_channels, 'Padding', 1);
        UI.panel.brainRegions.main  = uix.VBox('Parent',UI.uitabgroup_channels, 'Padding', 1);
        UI.panel.chanCoords.main  = uix.VBox('Parent',UI.uitabgroup_channels, 'Padding', 1);
        UI.uitabgroup_channels.TabNames = {'Groups', 'Channels','Regions','Layout'};
        
        UI.table.electrodeGroups = uitable(UI.panel.electrodeGroups.main,'Data',{false,'','','',''},'Units','normalized','Position',[0 0 1 1],'ColumnWidth',{20 20 45 200 80},'columnname',{'','','Group','Channels        ','Label'},'RowName',[],'ColumnEditable',[true false false false false],'CellEditCallback',@editElectrodeGroups,'CellSelectionCallback',@ClicktoSelectFromTable);
        UI.panel.electrodeGroupsButtons = uipanel('Parent',UI.panel.general.main);
        
        % Channel list
        UI.listbox.channelList = uicontrol('Parent',UI.panel.chanelList.main,'Style','listbox','Position',[0 0 1 1],'Units','normalized','String',{'1'},'min',0,'Value',1,'fontweight', 'bold','Callback',@buttonChannelList,'KeyPressFcn', {@keyPress});

        % Brain regions
        UI.table.brainRegions = uitable(UI.panel.brainRegions.main,'Data',{false,'','',''},'Units','normalized','Position',[0 0 1 1],'ColumnWidth',{20 45 125 45},'columnname',{'','Region','Channels','Groups'},'RowName',[],'ColumnEditable',[true false false false],'CellEditCallback',@editBrainregionList);
        
        % Channel coordinates
        UI.chanCoordsAxes = axes('Parent',UI.panel.chanCoords.main,'Units','Normalize','Position',[0 0 1 1],'YLim',[0,1],'YTick',[],'XTick',[]); axis tight
        
        % Group buttons
        uicontrol('Parent',UI.panel.electrodeGroupsButtons,'Style','pushbutton','Units','normalized','Position',[0.01 0.01 0.32 0.98],'String','All','Callback',@buttonsElectrodeGroups,'KeyPressFcn', @keyPress,'tooltip','Select all');
        uicontrol('Parent',UI.panel.electrodeGroupsButtons,'Style','pushbutton','Units','normalized','Position',[0.34 0.01 0.32 0.98],'String','None','Callback',@buttonsElectrodeGroups,'KeyPressFcn', @keyPress,'tooltip','Deselect all');
        uicontrol('Parent',UI.panel.electrodeGroupsButtons,'Style','pushbutton','Units','normalized','Position',[0.67 0.01 0.32 0.98],'String','Edit','Callback',@buttonsElectrodeGroups,'KeyPressFcn', @keyPress,'tooltip','Edit metadata');
        
        % Channel tags
        UI.panel.channelTagsList = uipanel('Parent',UI.panel.general.main,'title','Channel tags');
        UI.table.channeltags = uitable(UI.panel.channelTagsList,'Data', {'','',false,false,false,'',''},'Units','normalized','Position',[0 0 1 1],'ColumnWidth',{20 60 20 20 20 55 55},'columnname',{'','Tags',char(8226),'+','-','Channels','Groups'},'RowName',[],'ColumnEditable',[false false true true true true false],'CellEditCallback',@editChannelTags,'CellSelectionCallback',@ClicktoSelectFromTable2);
        UI.panel.channelTagsButtons = uipanel('Parent',UI.panel.general.main);
        uicontrol('Parent',UI.panel.channelTagsButtons,'Style','pushbutton','Units','normalized','Position',[0.01 0.01 0.485 0.98],'String','New tag','Callback',@buttonsChannelTags,'KeyPressFcn', @keyPress,'tooltip','Add channel tag');
        uicontrol('Parent',UI.panel.channelTagsButtons,'Style','pushbutton','Units','normalized','Position',[0.505 0.01 0.485 0.98],'String','Delete tag(s)','Callback',@buttonsChannelTags,'KeyPressFcn', @keyPress,'tooltip','Delete channel tag');
        
        % Notes
        UI.panel.notes.main = uipanel('Parent',UI.panel.general.main,'title','Session notes');
        UI.panel.notes.text = uicontrol('Parent',UI.panel.notes.main,'Style', 'Edit', 'String', '','Units' ,'normalized', 'Position', [0, 0, 1, 1],'HorizontalAlignment','left', 'Min', 0, 'Max', 200,'Callback',@getNotes);
        
        % Epochs
        UI.panel.epochs.main = uipanel('Parent',UI.panel.general.main,'title','Session epochs');
        UI.epochAxes = axes('Parent',UI.panel.epochs.main,'Units','Normalize','Position',[0 0 1 1],'YLim',[0,1],'YTick',[],'ButtonDownFcn',@ClickEpochs,'XTick',[]); axis tight %,'Color',UI.settings.background,'XColor',UI.settings.primaryColor,'TickLength',[0.005, 0.001],'XMinorTick','on',,'Clipping','off');
        
        % Time series data
        UI.panel.timeseriesdata.main = uipanel('Title','Raw time series data','Position',[0 0.2 1 0.1],'Units','normalized','Parent',UI.panel.general.main);
        UI.table.timeseriesdata = uitable(UI.panel.timeseriesdata.main,'Data',{false,'','',''},'Units','normalized','Position',[0 0.20 1 0.80],'ColumnWidth',{20 35 125 45},'columnname',{'','Tag','File name','nChan'},'RowName',[],'ColumnEditable',[true false false false],'CellEditCallback',@showIntan);
        UI.panel.timeseriesdata.showTimeseriesBelowTrace = uicontrol('Parent',UI.panel.timeseriesdata.main,'Style','checkbox','Units','normalized','Position',[0 0 0.5 0.20], 'value', 0,'String','Below traces','Callback',@showTimeseriesBelowTrace,'KeyPressFcn', @keyPress,'tooltip','Show time series data below traces');
        uicontrol('Parent',UI.panel.timeseriesdata.main,'Style','pushbutton','Units','normalized','Position',[0.5 0 0.49 0.19],'String','Metadata','Callback',@editIntanMeta,'KeyPressFcn', @keyPress,'tooltip','Edit session metadata');
            
        % Defining flexible panel heights
        set(UI.panel.general.main, 'Heights', [65 210 -210 35 -90 35 100 40 150],'MinimumHeights',[65 210 200 35 140 35 50 30 150]);
        UI.panel.general.main1.MinimumWidths = 218;
        UI.panel.general.main1.MinimumHeights = 975;
        
        % % % % % % % % % % % % % % % % % % % % % %
        % 2. PANEL: Spikes related metrics
        
        % Spikes
        UI.panel.spikes.main = uipanel('Parent',UI.panel.spikedata.main,'title','Spikes  (*.spikes.cellinfo.mat)');
        UI.panel.spikes.showSpikes = uicontrol('Parent',UI.panel.spikes.main,'Style', 'checkbox','String','Show spikes', 'value', 0, 'Units','normalized', 'Position', [0.01 0.85 0.48 0.14],'Callback',@toggleSpikes,'HorizontalAlignment','left','tooltip','Load and show spike rasters');
        UI.panel.spikes.showSpikesBelowTrace = uicontrol('Parent',UI.panel.spikes.main,'Style', 'checkbox','String','Below traces', 'value', 0, 'Units','normalized', 'Position', [0.51 0.85 0.75 0.14],'Callback',@showSpikesBelowTrace,'HorizontalAlignment','left','tooltip','Show spike rasters below ephys traces');
        uicontrol('Parent',UI.panel.spikes.main,'Style', 'text', 'String', ' Colors: ', 'Units','normalized', 'Position', [0 0.68 0.35 0.16],'HorizontalAlignment','left','tooltip','Define color groups');
        UI.panel.spikes.setSpikesGroupColors = uicontrol('Parent',UI.panel.spikes.main,'Style', 'popup', 'String', {'UID','Single color','Electrode groups'}, 'Units','normalized', 'Position', [0.35 0.68 0.64 0.16],'HorizontalAlignment','left','Enable','off','Callback',@setSpikesGroupColors);
        uicontrol('Parent',UI.panel.spikes.main,'Style', 'text', 'String', ' Sorting/Ydata: ', 'Units','normalized', 'Position', [0.0 0.51 0.4 0.16],'HorizontalAlignment','left','tooltip','Only applies to rasters shown below ephys traces');
        UI.panel.spikes.setSpikesYData = uicontrol('Parent',UI.panel.spikes.main,'Style', 'popup', 'String', {''}, 'Units','normalized', 'Position', [0.35 0.51 0.64 0.16],'HorizontalAlignment','left','Enable','off','Callback',@setSpikesYData);

       	uicontrol('Parent',UI.panel.spikes.main,'Style', 'text', 'String', 'Width ', 'Units','normalized', 'Position', [0.37 0.34 0.3 0.13],'HorizontalAlignment','right','tooltip','Relative width of the spike waveforms');        
        UI.panel.spikes.showSpikeWaveforms = uicontrol('Parent',UI.panel.spikes.main,'Style', 'checkbox','String','Waveforms', 'value', 0, 'Units','normalized', 'Position', [0.01 0.34 0.43 0.16],'Callback',@showSpikeWaveforms,'HorizontalAlignment','left','tooltip','Show spike waveforms below ephys traces');
        UI.panel.spikes.waveformsRelativeWidth = uicontrol('Parent',UI.panel.spikes.main,'Style', 'Edit', 'String',num2str(UI.settings.waveformsRelativeWidth), 'Units','normalized', 'Position', [0.67 0.34 0.32 0.16],'HorizontalAlignment','center','Callback',@showSpikeWaveforms);
        uicontrol('Parent',UI.panel.spikes.main,'Style', 'text', 'String', 'Electrode group ', 'Units','normalized', 'Position', [0.17 0.17 0.5 0.13],'HorizontalAlignment','right','tooltip','Electrode group that the PCA representation is applied to');
        UI.panel.spikes.showSpikesPCAspace = uicontrol('Parent',UI.panel.spikes.main,'Style', 'checkbox','String','PCAs', 'value', 0, 'Units','normalized', 'Position', [0.01 0.17 0.23 0.16],'Callback',@showSpikesPCAspace,'HorizontalAlignment','left');
        UI.panel.spikes.PCA_electrodeGroup = uicontrol('Parent',UI.panel.spikes.main,'Style', 'Edit', 'String', num2str(UI.settings.PCAspace_electrodeGroup), 'Units','normalized', 'Position', [0.67 0.17 0.32 0.16],'HorizontalAlignment','center','Callback',@showSpikesPCAspace);
        
        UI.panel.spikes.showSpikeMatrix = uicontrol('Parent',UI.panel.spikes.main,'Style', 'checkbox','String','Show matrix', 'value', 0, 'Units','normalized', 'Position', [0.01 0.01 0.45 0.15],'Callback',@showSpikeMatrix,'HorizontalAlignment','left');
        %UI.panel.spikes.setSpikesGroupColors = uicontrol('Parent',UI.panel.spikes.main,'Style', 'popup', 'String', {'UID','Single color','Electrode groups'}, 'Units','normalized', 'Position', [0.35 0.60 0.64 0.16],'HorizontalAlignment','left','Enable','off','Callback',@setSpikesGroupColors);
        UI.panel.spikes.reverseSpikeSorting = uicontrol('Parent',UI.panel.spikes.main,'Style', 'checkbox','String','Reverse spike sorting', 'value', 0, 'Units','normalized', 'Position', [0.51 0.01 0.50 0.14],'Callback',@reverseSpikeSorting,'HorizontalAlignment','left','tooltip','Reverse sorting of spike rasters below ephys traces');
        
        % Cell metrics
        UI.panel.cell_metrics.main = uipanel('Parent',UI.panel.spikedata.main,'title','Cell metrics (*.cell_metrics.cellinfo.mat)');
        uicontrol('Parent',UI.panel.cell_metrics.main,'Style', 'text', 'String', '  Color groups', 'Units','normalized','Position', [0 0.74 0.5 0.12],'HorizontalAlignment','left');
        uicontrol('Parent',UI.panel.cell_metrics.main,'Style', 'text', 'String', '  Sorting','Units','normalized','Position', [0 0.47 1 0.12],'HorizontalAlignment','left');
        uicontrol('Parent',UI.panel.cell_metrics.main,'Style', 'text', 'String', '  Filter', 'Units','normalized','Position', [0 0.17 1 0.12], 'HorizontalAlignment','left');
        UI.panel.cell_metrics.useMetrics = uicontrol('Parent',UI.panel.cell_metrics.main,'Style', 'checkbox','String','Use metrics', 'value', 0, 'Units','normalized','Position', [0 0.85 0.5 0.15], 'Callback',@toggleMetrics,'HorizontalAlignment','left');
        UI.panel.cell_metrics.defineGroupData = uicontrol('Parent',UI.panel.cell_metrics.main,'Style','pushbutton','Units','normalized','Position',[0.5 0.82 0.49 0.18],'String','Group data','Callback',@defineGroupData,'KeyPressFcn', @keyPress,'tooltip','Filter and highlight by groups','Enable','off'); 
        UI.panel.cell_metrics.groupMetric = uicontrol('Parent',UI.panel.cell_metrics.main,'Style', 'popup', 'String', {''}, 'Units','normalized','Position', [0.01 0.6 0.98 0.15],'HorizontalAlignment','left','Enable','off','Callback',@setGroupMetric);
        UI.panel.cell_metrics.sortingMetric = uicontrol('Parent',UI.panel.cell_metrics.main,'Style', 'popup', 'String', {''}, 'Units','normalized','Position', [0.01 0.32 0.98 0.15],'HorizontalAlignment','left','Enable','off','Callback',@setSortingMetric);
        UI.panel.cell_metrics.textFilter = uicontrol('Style','edit', 'Units','normalized','Position',[0.01 0.01 0.98 0.17],'String','','HorizontalAlignment','left','Parent',UI.panel.cell_metrics.main,'Callback',@filterCellsByText,'Enable','off','tooltip',sprintf('Search across cell metrics\nString fields: "CA1" or "Interneuro"\nNumeric fields: ".firingRate > 10" or ".cv2 < 0.5" (==,>,<,~=) \nCombine with AND // OR operators (&,|) \nEaxmple: ".firingRate > 10 & CA1"\nFilter by parent brain regions as well, fx: ".brainRegion HIP"\nMake sure to include  spaces between fields and operators' ));

        UI.panel.cellTypes.main = uipanel('Parent',UI.panel.spikedata.main,'title','Putative cell types');
        UI.listbox.cellTypes = uicontrol('Parent',UI.panel.cellTypes.main,'Style','listbox', 'Units','normalized','Position',[0 0 1 1],'String',{''},'Enable','off','max',20,'min',0,'Value',[],'Callback',@setCellTypeSelectSubset,'KeyPressFcn', @keyPress,'tooltip','Filter putative cell types. Select to filter');
        
        % Table with list of cells
        UI.panel.cellTable.main = uipanel('Parent',UI.panel.spikedata.main,'title','List of cells');
        UI.table.cells = uitable(UI.panel.cellTable.main,'Data', {false,'','',''},'Units','normalized','Position',[0 0 1 1],'ColumnWidth',{20 25 118 55},'columnname',{'','#','Cell type','Rate (Hz)'},'RowName',[],'ColumnEditable',[true false false false],'ColumnFormat',{'logical','char','char','numeric'},'CellEditCallback',@editCellTable,'Enable','off');
        UI.panel.metricsButtons = uipanel('Parent',UI.panel.spikedata.main);
        uicontrol('Parent',UI.panel.metricsButtons,'Style','pushbutton','Units','normalized','Position',[0.01 0.01 0.32 0.98],'String','All','Callback',@metricsButtons,'KeyPressFcn', @keyPress,'tooltip','Show all cells');
        uicontrol('Parent',UI.panel.metricsButtons,'Style','pushbutton','Units','normalized','Position',[0.34 0.01 0.32 0.98],'String','None','Callback',@metricsButtons,'KeyPressFcn', @keyPress,'tooltip','Hide all cells');
        uicontrol('Parent',UI.panel.metricsButtons,'Style','pushbutton','Units','normalized','Position',[0.67 0.01 0.32 0.98],'String','Metrics','Callback',@metricsButtons,'KeyPressFcn', @keyPress,'tooltip','Show table with metrics');
        
        % Population analysis
        UI.panel.populationAnalysis.main = uipanel('Parent',UI.panel.spikedata.main,'title','Population dynamics');
        UI.panel.spikes.populationRate = uicontrol('Parent',UI.panel.populationAnalysis.main,'Style', 'checkbox','String','Show population rate', 'value', 0, 'Units','normalized', 'Position', [0.01 0.68 0.9 0.3],'Callback',@tooglePopulationRate,'HorizontalAlignment','left');
%         UI.panel.spikes.populationRateBelowTrace = uicontrol('Parent',UI.panel.populationAnalysis.main,'Style', 'checkbox','String','Below traces', 'value', 0, 'Units','normalized', 'Position', [0.505 0.68 0.485 0.3],'Callback',@tooglePopulationRate,'HorizontalAlignment','left');
        uicontrol('Parent',UI.panel.populationAnalysis.main,'Style', 'text','String','Binsize (in sec)', 'Units','normalized', 'Position', [0.01 0.33 0.68 0.25],'Callback',@tooglePopulationRate,'HorizontalAlignment','left');
        UI.panel.spikes.populationRateWindow = uicontrol('Parent',UI.panel.populationAnalysis.main,'Style', 'Edit', 'String', num2str(UI.settings.populationRateWindow), 'Units','normalized', 'Position', [0.7 0.32 0.29 0.3],'Callback',@tooglePopulationRate,'HorizontalAlignment','center','tooltip','Binsize (seconds)');
        uicontrol('Parent',UI.panel.populationAnalysis.main,'Style', 'text','String','Gaussian smoothing (bins)', 'Units','normalized', 'Position', [0.01 0.01 0.68 0.25],'Callback',@tooglePopulationRate,'HorizontalAlignment','left');
        UI.panel.spikes.populationRateSmoothing = uicontrol('Parent',UI.panel.populationAnalysis.main,'Style', 'Edit', 'String', num2str(UI.settings.populationRateSmoothing), 'Units','normalized', 'Position', [0.7 0.01 0.29 0.3],'Callback',@tooglePopulationRate,'HorizontalAlignment','center','tooltip','Binsize (seconds)');
        
        % Spike sorting pipelines
        UI.panel.spikesorting.main = uipanel('Title','Other spike sorting formats','Position',[0 0.2 1 0.1],'Units','normalized','Parent',UI.panel.spikedata.main);
        UI.panel.spikesorting.showKilosort = uicontrol('Parent',UI.panel.spikesorting.main,'Style','checkbox','Units','normalized','Position',[0.01 0.66 0.485 0.32], 'value', 0,'String','Kilosort','Callback',@showKilosort,'KeyPressFcn', @keyPress,'tooltip','Open a KiloSort rez.mat data and show detected spikes');
        UI.panel.spikesorting.kilosortBelowTrace = uicontrol('Parent',UI.panel.spikesorting.main,'Style','checkbox','Units','normalized','Position',[0.505 0.66 0.485 0.32], 'value', 0,'String','Below traces','Callback',@showKilosort,'KeyPressFcn', @keyPress,'tooltip','Show KiloSort spikes below trace');
        
        UI.panel.spikesorting.showKlusta = uicontrol('Parent',UI.panel.spikesorting.main,'Style','checkbox','Units','normalized','Position',[0.01 0.33 0.485 0.32], 'value', 0,'String','Klustakwik','Callback',@showKlusta,'KeyPressFcn', @keyPress,'tooltip','Open Klustakwik clustered data files and show detected spikes');
        UI.panel.spikesorting.klustaBelowTrace = uicontrol('Parent',UI.panel.spikesorting.main,'Style','checkbox','Units','normalized','Position',[0.505 0.33 0.485 0.32], 'value', 0,'String','Below traces','Callback',@showKlusta,'KeyPressFcn', @keyPress,'tooltip','Show Klustakwik spikes below trace');
        
        UI.panel.spikesorting.showSpykingcircus = uicontrol('Parent',UI.panel.spikesorting.main,'Style','checkbox','Units','normalized','Position',[0.01 0 0.485 0.32], 'value', 0,'String','Spyking Circus','Callback',@showSpykingcircus,'KeyPressFcn', @keyPress,'tooltip','Open SpyKING CIRCUS clustered data and show detected spikes');
        UI.panel.spikesorting.spykingcircusBelowTrace = uicontrol('Parent',UI.panel.spikesorting.main,'Style','checkbox','Units','normalized','Position',[0.505 0 0.485 0.32], 'value', 0,'String','Below traces','Callback',@showSpykingcircus,'KeyPressFcn', @keyPress,'tooltip','Show SpyKING CIRCUS spikes below trace');

        % Defining flexible panel heights
        set(UI.panel.spikedata.main, 'Heights', [160 170 100 -200 35 100 95],'MinimumHeights',[160 170 60 160 35 60 95]);
        UI.panel.spikedata.main1.MinimumWidths = 218;
        UI.panel.spikedata.main1.MinimumHeights = 825;
        
        % % % % % % % % % % % % % % % % % % % % % %
        % 3. PANEL: Other datatypes
        
        % Events
        UI.panel.events.table = uipanel('Parent',UI.panel.other.main,'title','Events (*.events.mat)');
        UI.table.events_data = uitable(UI.panel.events.table,'Data', {'','',false,false,false},'Units','normalized','Position',[0 0 1 1],'ColumnWidth',{20 85 42 50 45},'columnname',{'','Name','Show','Active','Below'},'RowName',[],'ColumnEditable',[false false true true true],'CellEditCallback',@setEventData,'CellSelectionCallback',@table_events_click);

        UI.panel.events.main = uipanel('Parent',UI.panel.other.main);
        UI.panel.events.showEventsIntervals = uicontrol('Parent',UI.panel.events.main,'Style','checkbox','Units','normalized','Position',[0.01 0.8 0.32 0.19], 'value', 0,'String','Intervals','Callback',@showEventsIntervals,'KeyPressFcn', @keyPress,'tooltip','Show events intervals');
        UI.panel.events.processing_steps = uicontrol('Parent',UI.panel.events.main,'Style','checkbox','Units','normalized','Position',[0.34 0.8 0.32 0.19], 'value', 0,'String','Processing','Callback',@processing_steps,'KeyPressFcn', @keyPress,'tooltip','Show processing steps');
        uicontrol('Parent',UI.panel.events.main,'Style','pushbutton','Units','normalized','Position',[0.665 0.8 0.32 0.20],'String','Save events','Callback',@saveEvent,'KeyPressFcn', @keyPress,'tooltip','Save');
        UI.panel.events.eventNumber = uicontrol('Parent',UI.panel.events.main,'Style', 'Edit', 'String', '', 'Units','normalized', 'Position', [0.01 0.6 0.485 0.19],'HorizontalAlignment','center','tooltip','Event number','Callback',@gotoEvents);
        UI.panel.events.eventCount = uicontrol('Parent',UI.panel.events.main,'Style', 'Edit', 'String', 'nEvents', 'Units','normalized', 'Position', [0.505 0.6 0.485 0.19],'HorizontalAlignment','center','Enable','off');
        uicontrol('Parent',UI.panel.events.main,'Style','pushbutton','Units','normalized','Position',[0.01 0.4 0.32 0.19],'String',char(8592),'Callback',@previousEvent,'KeyPressFcn', @keyPress,'tooltip','Previous event');
        uicontrol('Parent',UI.panel.events.main,'Style','pushbutton','Units','normalized','Position',[0.34 0.4 0.32 0.19],'String','Random','Callback',@(src,evnt)randomEvent,'KeyPressFcn', @keyPress,'tooltip','Random event');
        uicontrol('Parent',UI.panel.events.main,'Style','pushbutton','Units','normalized','Position',[0.67 0.4 0.32 0.19],'String',char(8594),'Callback',@nextEvent,'KeyPressFcn', @keyPress,'tooltip','Next event');
        uicontrol('Parent',UI.panel.events.main,'Style','pushbutton','Units','normalized','Position',[0.01 0.2 0.485 0.19],'String','Flag event','Callback',@flagEvent,'KeyPressFcn', @keyPress,'tooltip','Flag selected event');
        UI.panel.events.flagCount = uicontrol('Parent',UI.panel.events.main,'Style', 'Edit', 'String', 'nFlags', 'Units','normalized', 'Position', [0.505 0.2 0.485 0.19],'HorizontalAlignment','center','Enable','off');
        uicontrol('Parent',UI.panel.events.main,'Style','pushbutton','Units','normalized','Position',[0.01 0.01 0.32 0.19],'String','+ event','Callback',@addEvent,'KeyPressFcn', @keyPress,'tooltip','Add event. Define single timestamps with cursor. Also allows for removing added timestamps. Saved to .added');
        uicontrol('Parent',UI.panel.events.main,'Style','pushbutton','Units','normalized','Position',[0.34 0.01 0.32 0.19],'String','+ interval','Callback',@addInterval,'KeyPressFcn', @keyPress,'tooltip','Add intervals. Define boundaries with mouse cursor. Saved to .added_intervals');
        uicontrol('Parent',UI.panel.events.main,'Style','pushbutton','Units','normalized','Position',[0.67 0.01 0.32 0.19],'String','- interval','Callback',@removeInterval,'KeyPressFcn', @keyPress,'tooltip','Remove intervals. Define boundaries with mouse cursor. Affects only manually added intervals. Saved to .added_intervals');
        
        % States
        UI.panel.states.main = uipanel('Parent',UI.panel.other.main,'title','States (*.states.mat)');
        UI.panel.states.files = uicontrol('Parent',UI.panel.states.main,'Style', 'popup', 'String', {''}, 'Units','normalized', 'Position', [0.01 0.67 0.98 0.31],'HorizontalAlignment','left','Callback',@setStatesData);
        UI.panel.states.showStates = uicontrol('Parent',UI.panel.states.main,'Style','checkbox','Units','normalized','Position',[0.01 0.35 1 0.33], 'value', 0,'String','Show states','Callback',@showStates,'KeyPressFcn', @keyPress,'tooltip','Show states data');
        UI.panel.states.previousStates = uicontrol('Parent',UI.panel.states.main,'Style','pushbutton','Units','normalized','Position',[0.505 0.35 0.24 0.32],'String',char(8592),'Callback',@previousStates,'KeyPressFcn', @keyPress,'tooltip','Previous state');
        UI.panel.states.nextStates = uicontrol('Parent',UI.panel.states.main,'Style','pushbutton','Units','normalized','Position',[0.755 0.35 0.235 0.32],'String',char(8594),'Callback',@nextStates,'KeyPressFcn', @keyPress,'tooltip','Next state');
        UI.panel.states.statesNumber = uicontrol('Parent',UI.panel.states.main,'Style', 'Edit', 'String', '', 'Units','normalized', 'Position', [0.01 0.01 0.485 0.32],'HorizontalAlignment','center','tooltip','State number','Callback',@gotoState);
        UI.panel.states.statesCount = uicontrol('Parent',UI.panel.states.main,'Style', 'Edit', 'String', 'nStates', 'Units','normalized', 'Position', [0.505 0.01 0.485 0.32],'HorizontalAlignment','center','Enable','off');
        
        % Behavior
        UI.panel.behavior.main = uipanel('Parent',UI.panel.other.main,'title','Behavior (*.behavior.mat)');
        UI.panel.behavior.files = uicontrol('Parent',UI.panel.behavior.main,'Style', 'popup', 'String', {''}, 'Units','normalized', 'Position', [0.01 0.79 0.98 0.19],'HorizontalAlignment','left','Callback',@setBehaviorData);
        UI.panel.behavior.showBehavior = uicontrol('Parent',UI.panel.behavior.main,'Style','checkbox','Units','normalized','Position',[0 0.60 1 0.19], 'value', 0,'String','Show behavior','Callback',@showBehavior,'KeyPressFcn', @keyPress,'tooltip','Show behavior');
        UI.panel.behavior.previousBehavior = uicontrol('Parent',UI.panel.behavior.main,'Style','pushbutton','Units','normalized','Position',[0.505 0.60 0.24 0.19],'String',['| ' char(8592)],'Callback',@previousBehavior,'KeyPressFcn', @keyPress,'tooltip','Start of behavior');
        UI.panel.behavior.nextBehavior = uicontrol('Parent',UI.panel.behavior.main,'Style','pushbutton','Units','normalized','Position',[0.755 0.60 0.235 0.19],'String',[char(8594) ' |'],'Callback',@nextBehavior,'KeyPressFcn', @keyPress,'tooltip','End of behavior','BusyAction','cancel');
        UI.panel.behavior.showBehaviorBelowTrace = uicontrol('Parent',UI.panel.behavior.main,'Style','checkbox','Units','normalized','Position',[0.505 0.41 0.485 0.19], 'value', 0,'String','Below traces','Callback',@showBehaviorBelowTrace,'KeyPressFcn', @keyPress,'tooltip','Show behavior data below traces');
        UI.panel.behavior.plotBehaviorLinearized = uicontrol('Parent',UI.panel.behavior.main,'Style','checkbox','Units','normalized','Position',[0.01 0.41 0.485 0.19], 'value', 0,'String','Linearize','Callback',@plotBehaviorLinearized,'KeyPressFcn', @keyPress,'tooltip','Show linearized behavior');
        UI.panel.behavior.showTrials = uicontrol('Parent',UI.panel.behavior.main,'Style', 'popup', 'String', {'Show trials'}, 'Units','normalized', 'Position', [0.01 0.22 0.485 0.19],'HorizontalAlignment','left','Callback',@showTrials);
        UI.panel.behavior.previousTrial = uicontrol('Parent',UI.panel.behavior.main,'Style','pushbutton','Units','normalized','Position',[0.505 0.22 0.24 0.19],'String',char(8592),'Callback',@previousTrial,'KeyPressFcn', @keyPress,'tooltip','Previous trial');
        UI.panel.behavior.nextTrial = uicontrol('Parent',UI.panel.behavior.main,'Style','pushbutton','Units','normalized','Position',[0.755 0.22 0.235 0.19],'String',char(8594),'Callback',@nextTrial,'KeyPressFcn', @keyPress,'tooltip','Next trial');
        UI.panel.behavior.trialNumber = uicontrol('Parent',UI.panel.behavior.main,'Style', 'Edit', 'String', '', 'Units','normalized', 'Position', [0.01 0.01 0.485 0.20],'HorizontalAlignment','center','tooltip','Trial number','Callback',@gotoTrial);
        UI.panel.behavior.trialCount = uicontrol('Parent',UI.panel.behavior.main,'Style', 'Edit', 'String', 'nTrials', 'Units','normalized', 'Position', [0.505 0.01 0.485 0.20],'HorizontalAlignment','center','Enable','off');
        
        % Time series
        UI.panel.timeseries.table = uipanel('Parent',UI.panel.other.main,'title','Time series (*.timeseries.mat)');
        UI.table.timeseries_data = uitable(UI.panel.timeseries.table,'ColumnFormat',{'char','char','logical',{'Full trace','Window','Custom'},'char','char'},'Units','normalized','Position',[0 0 1 1],'ColumnWidth',{20 85 42 80 80 100},'columnname',{'','Name','Show','Range','Custom limits','Channels'},'RowName',[],'ColumnEditable',[false false true true true true],'CellEditCallback',@setTimeseriesData,'CellSelectionCallback',@table_timeseries_click);
        UI.panel.timeseries.main = uipanel('Parent',UI.panel.other.main);
        uicontrol('Parent',UI.panel.timeseries.main,'Style','pushbutton','Units','normalized','Position',[0.01 0.01 0.98 0.98],'String','Plot full timeseries','Callback',@plotTimeSeries,'KeyPressFcn', @keyPress,'tooltip','Show full trace in separate figure');
        
        % Defining flexible panel heights
        set(UI.panel.other.main, 'Heights', [-120 150 95 140 -120 40],'MinimumHeights',[120 150 100 150 120 40]);
        UI.panel.other.main1.MinimumWidths = 218;
        UI.panel.other.main1.MinimumHeights = 760;
        
        % % % % % % % % % % % % % % % % % % % % % %
        % 4. PANEL: Analysis
        
        % Spectrogram
        UI.panel.spectrogram.main = uipanel('Parent',UI.panel.analysis.main,'title','Spectrogram');
        UI.panel.spectrogram.showSpectrogram = uicontrol('Parent',UI.panel.spectrogram.main,'Style', 'checkbox','String','Show spectrogram', 'value', 0, 'Units','normalized', 'Position', [0.01 0.80 0.99 0.19],'Callback',@toggleSpectrogram,'HorizontalAlignment','left');
        uicontrol('Parent',UI.panel.spectrogram.main,'Style', 'text','String','Channel', 'Units','normalized', 'Position', [0.01 0.60 0.49 0.17],'HorizontalAlignment','left');
        UI.panel.spectrogram.spectrogramChannel = uicontrol('Parent',UI.panel.spectrogram.main,'Style', 'Edit', 'String', num2str(UI.settings.spectrogram.channel), 'Units','normalized', 'Position', [0.505 0.60 0.485 0.19],'Callback',@toggleSpectrogram,'HorizontalAlignment','center');
        uicontrol('Parent',UI.panel.spectrogram.main,'Style', 'text','String','Window width (sec)', 'Units','normalized', 'Position', [0.01 0.40 0.49 0.17],'HorizontalAlignment','left');
        UI.panel.spectrogram.spectrogramWindow = uicontrol('Parent',UI.panel.spectrogram.main,'Style', 'Edit', 'String', num2str(UI.settings.spectrogram.window), 'Units','normalized', 'Position', [0.505 0.40 0.485 0.19],'Callback',@toggleSpectrogram,'HorizontalAlignment','center');
        
        uicontrol('Parent',UI.panel.spectrogram.main,'Style', 'text','String','Low freq (Hz)', 'Units','normalized', 'Position', [0.01 0.20 0.32 0.14],'HorizontalAlignment','left');
        UI.panel.spectrogram.freq_low = uicontrol('Parent',UI.panel.spectrogram.main,'Style', 'Edit', 'String', num2str(UI.settings.spectrogram.freq_low), 'Units','normalized', 'Position', [0.01 0.01 0.32 0.19],'Callback',@toggleSpectrogram,'HorizontalAlignment','center');
        
        uicontrol('Parent',UI.panel.spectrogram.main,'Style', 'text','String','Step size (Hz)', 'Units','normalized', 'Position', [0.34 0.20 0.32 0.14],'HorizontalAlignment','center');
        UI.panel.spectrogram.freq_step_size = uicontrol('Parent',UI.panel.spectrogram.main,'Style', 'Edit', 'String', num2str(UI.settings.spectrogram.freq_step_size), 'Units','normalized', 'Position', [0.34 0.01 0.32 0.19],'Callback',@toggleSpectrogram,'HorizontalAlignment','center');
        
        uicontrol('Parent',UI.panel.spectrogram.main,'Style', 'text','String','High freq (Hz)', 'Units','normalized', 'Position', [0.67 0.20 0.32 0.14],'HorizontalAlignment','right');
        UI.panel.spectrogram.freq_high = uicontrol('Parent',UI.panel.spectrogram.main,'Style', 'Edit', 'String', num2str(UI.settings.spectrogram.freq_high), 'Units','normalized', 'Position', [0.67 0.01 0.32 0.19],'Callback',@toggleSpectrogram,'HorizontalAlignment','center');
        
        % Current Source Density
        UI.panel.csd.main = uipanel('Parent',UI.panel.analysis.main,'title','Current Source Density');
        UI.panel.csd.showCSD = uicontrol('Parent',UI.panel.csd.main,'Style', 'checkbox','String','Show Current Source Density', 'value', 0, 'Units','normalized', 'Position', [0.01 0.01 0.98 0.98],'Callback',@show_CSD,'HorizontalAlignment','left');
        
        % plotRMSnoiseInset
        UI.panel.RMSnoiseInset.main = uipanel('Parent',UI.panel.analysis.main,'title','RMS noise inset');
        UI.panel.RMSnoiseInset.showRMSnoiseInset = uicontrol('Parent',UI.panel.RMSnoiseInset.main,'Style', 'checkbox','String','Show plot inset', 'value', 0, 'Units','normalized', 'Position', [0.01 0.67 0.48 0.30],'Callback',@toggleRMSnoiseInset,'HorizontalAlignment','left');
        UI.panel.RMSnoiseInset.filter = uicontrol('Parent',UI.panel.RMSnoiseInset.main,'Style', 'popup','String',{'No filter','Ephys filter','Custom filter'}, 'value', UI.settings.plotRMSnoise_apply_filter, 'Units','normalized', 'Position', [0.50 0.67 0.49 0.30],'Callback',@toggleRMSnoiseInset,'HorizontalAlignment','left');
        uicontrol('Parent',UI.panel.RMSnoiseInset.main,'Style', 'text', 'String', 'Lower filter (Hz)', 'Units','normalized', 'Position', [0.0 0.35 0.5 0.26],'HorizontalAlignment','center');
        uicontrol('Parent',UI.panel.RMSnoiseInset.main,'Style', 'text', 'String', 'Higher filter (Hz)', 'Units','normalized', 'Position', [0.5 0.35 0.5 0.26],'HorizontalAlignment','center');
        UI.panel.RMSnoiseInset.lowerBand  = uicontrol('Parent',UI.panel.RMSnoiseInset.main,'Style', 'Edit', 'String', num2str(UI.settings.plotRMSnoise_lowerBand), 'Units','normalized', 'Position', [0.01 0.01 0.48 0.36],'Callback',@toggleRMSnoiseInset,'HorizontalAlignment','center','tooltip','Lower frequency boundary (Hz)');
        UI.panel.RMSnoiseInset.higherBand = uicontrol('Parent',UI.panel.RMSnoiseInset.main,'Style', 'Edit', 'String', num2str(UI.settings.plotRMSnoise_higherBand), 'Units','normalized', 'Position', [0.5 0.01 0.49 0.36],'Callback',@toggleRMSnoiseInset,'HorizontalAlignment','center','tooltip','Higher frequency band (Hz)');
        
        % Instantaneous metrics plot
        UI.panel.instantaneousMetrics.main = uipanel('Parent',UI.panel.analysis.main,'title','Instantaneous metrics');
        UI.panel.instantaneousMetrics.showPower = uicontrol('Parent',UI.panel.instantaneousMetrics.main,'Style', 'checkbox','String','Power', 'value', 0, 'Units','normalized', 'Position',   [0.01 0.67 0.32 0.30],'Callback',@toggleInstantaneousMetrics,'HorizontalAlignment','left');
        UI.panel.instantaneousMetrics.showPhase = uicontrol('Parent',UI.panel.instantaneousMetrics.main,'Style', 'checkbox','String','Phase', 'value', 0, 'Units','normalized', 'Position',   [0.34 0.67 0.32 0.30],'Callback',@toggleInstantaneousMetrics,'HorizontalAlignment','left');
        UI.panel.instantaneousMetrics.showSignal = uicontrol('Parent',UI.panel.instantaneousMetrics.main,'Style', 'checkbox','String','Signal', 'value', 0, 'Units','normalized', 'Position', [0.67 0.67 0.32 0.30],'Callback',@toggleInstantaneousMetrics,'HorizontalAlignment','left');
        uicontrol('Parent',UI.panel.instantaneousMetrics.main,'Style', 'text', 'String', 'Channel', 'Units','normalized', 'Position', [0.01 0.35 0.32 0.26],'HorizontalAlignment','center');
        uicontrol('Parent',UI.panel.instantaneousMetrics.main,'Style', 'text', 'String', 'Low freq (Hz)', 'Units','normalized', 'Position', [0.34 0.35 0.32 0.26],'HorizontalAlignment','center');
        uicontrol('Parent',UI.panel.instantaneousMetrics.main,'Style', 'text', 'String', 'High freq (Hz)', 'Units','normalized', 'Position', [0.67 0.35 0.32 0.26],'HorizontalAlignment','center');
        UI.panel.instantaneousMetrics.channel    = uicontrol('Parent',UI.panel.instantaneousMetrics.main,'Style', 'Edit', 'String', num2str(UI.settings.instantaneousMetrics.channel), 'Units','normalized', 'Position', [0.01 0.01 0.32 0.36],'Callback',@toggleInstantaneousMetrics,'HorizontalAlignment','center','tooltip','Channel');
        UI.panel.instantaneousMetrics.lowerBand  = uicontrol('Parent',UI.panel.instantaneousMetrics.main,'Style', 'Edit', 'String', num2str(UI.settings.instantaneousMetrics.lowerBand), 'Units','normalized', 'Position', [0.34 0.01 0.32 0.36],'Callback',@toggleInstantaneousMetrics,'HorizontalAlignment','center','tooltip','Lower frequency boundary (Hz)');
        UI.panel.instantaneousMetrics.higherBand = uicontrol('Parent',UI.panel.instantaneousMetrics.main,'Style', 'Edit', 'String', num2str(UI.settings.instantaneousMetrics.higherBand), 'Units','normalized', 'Position', [0.67 0.01 0.32 0.36],'Callback',@toggleInstantaneousMetrics,'HorizontalAlignment','center','tooltip','Higher frequency band (Hz)');
        
        % Play audio-trace when streaming ephys
        UI.panel.audio.main = uipanel('Parent',UI.panel.analysis.main,'title','Audio playback during streaming');
        UI.panel.audio.playAudio = uicontrol('Parent',UI.panel.audio.main,'Style', 'checkbox','String','Play audio', 'value', 0, 'Units','normalized', 'Position',   [0.01 0.64 0.48 0.34],'Callback',@togglePlayAudio,'HorizontalAlignment','left');
        UI.panel.audio.gain = uicontrol('Parent',UI.panel.audio.main,'Style', 'popup','String',{'Gain: 1','Gain: 2','Gain: 5','Gain: 10','Gain: 20'}, 'value', UI.settings.audioGain, 'Units','normalized', 'Position', [0.5 0.64 0.49 0.34],'Callback',@togglePlayAudio,'HorizontalAlignment','left');
        
        uicontrol('Parent',UI.panel.audio.main,'Style', 'text', 'String', 'Left channel', 'Units','normalized', 'Position', [0.0 0.38 0.5 0.24],'HorizontalAlignment','center');
        uicontrol('Parent',UI.panel.audio.main,'Style', 'text', 'String', 'Right channel', 'Units','normalized', 'Position', [0.5 0.38 0.5 0.24],'HorizontalAlignment','center');
        UI.panel.audio.leftChannel  = uicontrol('Parent',UI.panel.audio.main,'Style', 'Edit', 'String', num2str(UI.settings.audioChannels(1)), 'Units','normalized', 'Position', [0.01 0 0.485 0.36],'HorizontalAlignment','center','tooltip','Left channel','Callback',@togglePlayAudio);
        UI.panel.audio.rightChannel = uicontrol('Parent',UI.panel.audio.main,'Style', 'Edit', 'String', num2str(UI.settings.audioChannels(2)), 'Units','normalized', 'Position', [0.505 0 0.485 0.36],'HorizontalAlignment','center','tooltip','Right channel','Callback',@togglePlayAudio);
                
        % Defining flexible panel heights
        set(UI.panel.analysis.main, 'Heights', [150 60 100 100 100],'MinimumHeights',[150 60 100 100 100]);
        UI.panel.analysis.main1.MinimumWidths = 218;
        UI.panel.analysis.main1.MinimumHeights = 510;
        
        % % % % % % % % % % % % % % % % % % % % % %
        % Lower info panel elements
        UI.elements.lower.timeText = uicontrol('Parent',UI.panel.info,'Style', 'text', 'String', 'Time (s)', 'Units','normalized', 'Position', [0.1 0 0.1 0.8],'HorizontalAlignment','center');
        UI.elements.lower.time = uicontrol('Parent',UI.panel.info,'Style', 'Edit', 'String', '', 'Units','normalized', 'Position', [0.15 0 0.05 1],'HorizontalAlignment','right','tooltip','Current timestamp (seconds)','Callback',@setTime);
        uicontrol('Parent',UI.panel.info,'Style', 'text', 'String', '   Window duration (s)', 'Units','normalized', 'Position', [0.25 0 0.05 0.8],'HorizontalAlignment','center');
        UI.elements.lower.windowsSize = uicontrol('Parent',UI.panel.info,'Style', 'Edit', 'String', UI.settings.windowDuration, 'Units','normalized', 'Position', [0.3 0 0.05 1],'HorizontalAlignment','right','tooltip','Window size (seconds)','Callback',@setWindowsSize);
        UI.elements.lower.scalingText = uicontrol('Parent',UI.panel.info,'Style', 'text', 'String', ' Scaling ', 'Units','normalized', 'Position', [0.0 0 0.05 0.8],'HorizontalAlignment','right');
        UI.elements.lower.scaling = uicontrol('Parent',UI.panel.info,'Style', 'Edit', 'String', num2str(UI.settings.scalingFactor), 'Units','normalized', 'Position', [0.05 0 0.05 1],'HorizontalAlignment','right','tooltip','Ephys scaling','Callback',@setScaling);
        UI.elements.lower.performance = uicontrol('Parent',UI.panel.info,'Style', 'text', 'String', 'Performance', 'Units','normalized', 'Position', [0.25 0 0.05 0.8],'HorizontalAlignment','center','KeyPressFcn', @keyPress);
        UI.elements.lower.slider = uicontrol(UI.panel.info,'Style','slider','Units','normalized','Position',[0.5 0 0.5 1],'Value',0, 'SliderStep', [0.0001, 0.1], 'Min', 0, 'Max', 100,'Callback',@moveSlider,'Tag','slider');
        addlistener(UI.elements.lower.slider, 'Value', 'PostSet',@movingSlider);
        sliderMovedManually = true;
        set(UI.panel.info, 'Widths', [130 80 120 60 120 60 280 -1],'MinimumWidths',[130 80 120 60 60 60 250 1]); % set grid panel size
        
        % % % % % % % % % % % % % % % % % % % % % %
        % Creating plot axes
        UI.plot_axis1 = axes('Parent',UI.panel.plots,'Units','Normalize','Position',[0 0 1 1],'ButtonDownFcn',@ClickPlot,'Color',UI.settings.background,'XColor',UI.settings.primaryColor,'TickLength',[0.005, 0.001],'XMinorTick','on','XLim',[0,UI.settings.windowDuration],'YLim',[0,1],'YTickLabel',[],'Clipping','off');
        hold on
        UI.plot_axis1.XAxis.MinorTick = 'on';
        UI.plot_axis1.XAxis.MinorTickValues = 0:0.01:2;
        set(0,'units','pixels');
        ce_dragzoom(UI.plot_axis1,'on');
        UI.Pix_SS = get(0,'screensize');
        UI.Pix_SS = UI.Pix_SS(3)*2;
        
        setScalingText
        
    end

    function plotData
        % Generates all data plots
        UI.t0 = max([0,min([UI.t0,UI.t_total-UI.settings.windowDuration])]);
        
        % Deletes existing plot data
        delete(UI.plot_axis1.Children)
        set(UI.fig,'CurrentAxes',UI.plot_axis1)
        
        if UI.settings.resetZoomOnNavigation 
            resetZoom
        end
        
        UI.legend = {};
        
        % Ephys traces
        if ~UI.settings.playAudioFirst
            load_ephys_data
        end
        plot_ephys
        
        % KiloSort data
        if UI.settings.showKilosort
            plotKilosortData(UI.t0,UI.t0+UI.settings.windowDuration,'c')
        end
        
        % Klusta data
        if UI.settings.showKlusta
            plotKlustaData(UI.t0,UI.t0+UI.settings.windowDuration,'g')
        end
        
        % Spyking circus data
        if UI.settings.showSpykingcircus
            plotSpykingcircusData(UI.t0,UI.t0+UI.settings.windowDuration,'m')
        end
        
        % Spike data
        if UI.settings.showSpikes
            plotSpikeData(UI.t0,UI.t0+UI.settings.windowDuration,UI.settings.primaryColor,UI.plot_axis1)
        end
        
        % Spectrogram
        if UI.settings.spectrogram.show && ephys.loaded
            plotSpectrogram
        end
        
        % Instantaneous metrics
        if UI.settings.instantaneousMetrics.show && ephys.loaded
            plotInstantaneousMetrics
        end
        
        % States data
        if UI.settings.showStates
            plotTemporalStates(UI.t0,UI.t0+UI.settings.windowDuration)
        end
        
        % Event data
        if any(UI.settings.showEvents)
            if sum(UI.settings.showEvents)>1
                addLegend('Events:')
            end
            for i = 1:numel(UI.settings.showEvents)
                if UI.settings.showEvents(i)
                    eventName = UI.data.detectecFiles.events{i};
                    if sum(UI.settings.showEvents)>1
                        if strcmp(UI.settings.eventData,eventName)
                            addLegend(eventName,UI.settings.primaryColor);
                        else
                            addLegend(eventName,UI.colors_events(i,:));
                        end
                    end
                    plotEventData(eventName,UI.t0,UI.t0+UI.settings.windowDuration,UI.colors_events(i,:));                    
                end
            end
        end
        
        % Time series
        if any([UI.table.timeseries_data.Data{:,3}])
            if any([UI.table.timeseries_data.Data{:,3}])
                addLegend('Timeseries:')
            end
            for i = 1:length(UI.data.detectecFiles.timeseries)
                timeserieName = UI.data.detectecFiles.timeseries{i};
                if UI.settings.timeseries.(timeserieName).show
                    % 
                    % if any([UI.table.timeseries_data.Data{:,3}])
                    %     if strcmp(UI.settings.timeserieData,timeserieName)
                    %         addLegend(timeserieName,UI.settings.primaryColor);
                    %     else
                    %         addLegend(timeserieName,UI.colors_timeseries(i,:));
                    %     end
                    % end
                    plotTimeseriesData(timeserieName,UI.t0,UI.t0+UI.settings.windowDuration,UI.colors_timeseries(i,:),2);                    
                end
            end
        end
        
        % Analog time series
        if UI.settings.intan_showAnalog
            plotAnalog('adc')
        end
        
        % Time series aux (analog)
        if UI.settings.intan_showAux
            plotAnalog('aux')
        end
        
        % Digital time series
        if UI.settings.intan_showDigital
            plotDigital('dig')
        end
        
        % Behavior
        if UI.settings.showBehavior
            plotBehavior(UI.t0,UI.t0+UI.settings.windowDuration,[0.5 0.5 0.5])
        end
        
        % Trials
        if UI.settings.showTrials
            plotTrials(UI.t0,UI.t0+UI.settings.windowDuration)
        end
        
        % Plotting RMS noise inset        
        if UI.settings.plotRMSnoiseInset && ~isempty(UI.channelOrder)
            plotRMSnoiseInset
        end
        
        % Showing detected spikes in a spike-waveform-PCA plot inset
        if UI.settings.detectSpikes && ~isempty(UI.channelOrder) && UI.settings.showDetectedSpikesPCAspace
            plotSpikesPCAspace(raster,UI.settings.primaryColor,true)
        end      

        % Showing amplitude distribution of detected spikes in plot inset
        if UI.settings.detectSpikes && ~isempty(UI.channelOrder) && UI.settings.showDetectedSpikesAmplitudeDistribution
            plotSpikesAmplitudeDistribution(raster,UI.settings.primaryColor,true)
        end      

        % Showing amplitude distribution of detected spikes in plot inset
        if UI.settings.detectSpikes && ~isempty(UI.channelOrder) && UI.settings.showDetectedSpikesCountAcrossChannels
            plotSpikesCountAcrossChannels(raster,UI.settings.primaryColor,true)
        end      

        
        
        if ~isempty(UI.legend)
        	text(1/400,0.005,UI.legend,'FontWeight', 'Bold','BackgroundColor',UI.settings.textBackground,'VerticalAlignment', 'bottom','Units','normalized','HorizontalAlignment','left','HitTest','off','Interpreter','tex')
        end
    end
    
    function text_center(message)
        text(UI.plot_axis1,0.5,0.5,message,'Color',UI.settings.primaryColor,'FontSize',14,'Units','normalized','FontWeight', 'Bold','BackgroundColor',UI.settings.textBackground)
    end
    
    function addLegend(text_string,clr)
        % text_string: text string
        % clr: numeric color
        
        if nargin==1 % Considered a legend header 
            if ischar(UI.settings.primaryColor)
                str2rgb=@(x)get(line('color',x),'color');
                clr = str2rgb(UI.settings.primaryColor);
            else
                clr = UI.settings.primaryColor;
            end
            % Adding empty line above legend header
            if ~isempty(UI.legend)
                UI.legend = [UI.legend;' '];
            end
        end
        text_string = (['\color[rgb]{',num2strCommaSeparated(clr),'} ',text_string]);
        UI.legend = [UI.legend;text_string];
    end
    
    function load_ephys_data
        % Setting booleans for validating ephys loading and plotting        
        ephys.loaded = false;
        ephys.plotted = false;
        if UI.settings.plotStyle == 4 % lfp file
            if UI.fid.lfp == -1
                UI.settings.stream = false;
                ephys.loaded = false;
                text_center('Failed to load LFP data')
                return
            end
            ephys.sr = data.session.extracellular.srLfp;
            fileID = UI.fid.lfp;
        elseif UI.fid.ephys == -1 && UI.settings.plotStyle == 6
            UI.settings.stream = false;
            ephys.loaded = false;
            return
        elseif UI.settings.plotStyle == 6
            ephys.sr = data.session.extracellular.sr;
            fileID = UI.fid.ephys;
        else % dat file
            if UI.fid.ephys == -1
                UI.settings.stream = false;
                ephys.loaded = false;
                text_center('Failed to load raw data')
                return
            end
            ephys.sr = data.session.extracellular.sr;
            fileID = UI.fid.ephys;
        end
        
        if strcmp(UI.settings.fileRead,'bof')
            % Loading data
            if UI.t0>UI.t1 && UI.t0 < UI.t1 + UI.settings.windowDuration && ~UI.forceNewData
                t_offset = UI.t0-UI.t1;
                newSamples = round(UI.samplesToDisplay*t_offset/UI.settings.windowDuration);
                existingSamples = UI.samplesToDisplay-newSamples;
                % Keeping existing samples
                ephys.raw(1:existingSamples,:) = ephys.raw(newSamples+1:UI.samplesToDisplay,:);
                % Loading new samples
                fseek(fileID,round((UI.t0+UI.settings.windowDuration-t_offset)*ephys.sr)*data.session.extracellular.nChannels*2,'bof'); % bof: beginning of file
                try
                    ephys.raw(existingSamples+1:UI.samplesToDisplay,:) = double(fread(fileID, [data.session.extracellular.nChannels, newSamples],UI.settings.precision))'*UI.settings.leastSignificantBit;
                    ephys.loaded = true;
                catch 
                    UI.settings.stream = false;
                    text_center('Failed to read file')
                end
            elseif UI.t0 < UI.t1 && UI.t0 > UI.t1 - UI.settings.windowDuration && ~UI.forceNewData
                t_offset = UI.t1-UI.t0;
                newSamples = round(UI.samplesToDisplay*t_offset/UI.settings.windowDuration);
                % Keeping existing samples
                existingSamples = UI.samplesToDisplay-newSamples;
                ephys.raw(newSamples+1:UI.samplesToDisplay,:) = ephys.raw(1:existingSamples,:);
                % Loading new data
                fseek(fileID,round(UI.t0*ephys.sr)*data.session.extracellular.nChannels*2,'bof');
                ephys.raw(1:newSamples,:) = double(fread(fileID, [data.session.extracellular.nChannels, newSamples],UI.settings.precision))'*UI.settings.leastSignificantBit;
                ephys.loaded = true;
            elseif UI.t0==UI.t1 && ~UI.forceNewData
                ephys.loaded = true;
            else
                fseek(fileID,round(UI.t0*ephys.sr)*data.session.extracellular.nChannels*2,'bof');
                ephys.raw = double(fread(fileID, [data.session.extracellular.nChannels, UI.samplesToDisplay],UI.settings.precision))'*UI.settings.leastSignificantBit;
                ephys.loaded = true;
            end
            UI.forceNewData = false;
        else
            fseek(fileID,ceil(-UI.settings.windowDuration*ephys.sr)*data.session.extracellular.nChannels*2,'eof'); % eof: end of file
            ephys.raw = double(fread(fileID, [data.session.extracellular.nChannels, UI.samplesToDisplay],UI.settings.precision))'*UI.settings.leastSignificantBit;
            UI.forceNewData = true;
            ephys.loaded = true;
        end
        ephys.nChannels = size(ephys.raw,2);
        ephys.nSamples = size(ephys.raw,1);
        UI.t1 = UI.t0;
        
        if ~ephys.loaded
            return
        end
        
        % Removing DC (substraction of the mean of each channel)
        if UI.settings.removeDC
            ephys.traces = ephys.raw-mean(ephys.raw);
        else
            ephys.traces = ephys.raw;
        end
        
        % Median filter (substraction of the median at each sample across channels)
        if UI.settings.medianFilter
            ephys.traces = ephys.traces-median(ephys.traces,2);
        end
        
        if UI.settings.filterTraces && UI.settings.plotStyle == 4
            if int_gt_0(UI.settings.filter.lowerBand,ephys.sr) && ~int_gt_0(UI.settings.filter.higherBand,ephys.sr)
                [b1, a1] = butter(3, UI.settings.filter.higherBand/ephys.sr*2, 'low');
            elseif int_gt_0(UI.settings.filter.higherBand,ephys.sr) && ~int_gt_0(UI.settings.filter.lowerBand,ephys.sr)
                [b1, a1] = butter(3, UI.settings.filter.lowerBand/ephys.sr*2, 'high');
            else
                [b1, a1] = butter(3, [UI.settings.filter.lowerBand,UI.settings.filter.higherBand]/ephys.sr*2, 'bandpass');
            end
            ephys.traces(:,UI.channelOrder) = filtfilt(b1, a1, ephys.traces(:,UI.channelOrder) * (UI.settings.scalingFactor)/1000000);
        elseif UI.settings.filterTraces
            if ~isempty(UI.settings.filter.higherBand) && UI.settings.filter.higherBand < 50 && ephys.sr>UI.settings.filter.higherBand*100
                % Downsampling to improve filter response at low filter ranges
                n_downsampled = 20;
                sr_downsampled = ephys.sr/n_downsampled;
                data_downsampled = downsample(ephys.traces(:,UI.channelOrder) * (UI.settings.scalingFactor)/1000000,n_downsampled);
                
                if int_gt_0(UI.settings.filter.lowerBand,ephys.sr) && ~int_gt_0(UI.settings.filter.higherBand,ephys.sr)
                    [b1, a1] = butter(3, UI.settings.filter.higherBand/sr_downsampled*2, 'low');
                elseif int_gt_0(UI.settings.filter.higherBand,ephys.sr) && ~int_gt_0(UI.settings.filter.lowerBand,ephys.sr)
                    [b1, a1] = butter(3, UI.settings.filter.lowerBand/sr_downsampled*2, 'high');
                else
                    [b1, a1] = butter(3, [UI.settings.filter.lowerBand,UI.settings.filter.higherBand]/sr_downsampled*2, 'bandpass');
                end
                data_downsampled = filtfilt(b1, a1, data_downsampled);
                ephys.traces(:,UI.channelOrder) = interp1((1:size(data_downsampled,1))/size(data_downsampled,1),data_downsampled,(1:ephys.nSamples)/ephys.nSamples,'spline');
            else
                ephys.traces(:,UI.channelOrder) = filtfilt(UI.settings.filter.b1,UI.settings.filter.a1, ephys.traces(:,UI.channelOrder) * (UI.settings.scalingFactor)/1000000);
            end
        else
            ephys.traces(:,UI.channelOrder) = ephys.traces(:,UI.channelOrder) * (UI.settings.scalingFactor)/1000000;
        end
        
        if UI.settings.plotEnergy
            for i = UI.channelOrder
                ephys.traces(:,i) = 2*smooth(abs(ephys.traces(:,i)),round(UI.settings.energyWindow*ephys.sr),'moving');
            end
        end

    end
    
    function plot_ephys
        % Loading and plotting ephys data
        % There are five plot styles, for optimized plotting performance
        % 1. Downsampled: Shows every 16th sample of the raw data (no filter or averaging)
        % 2. Range: Shows a sample count optimized for the screen resolution. For each sample the max and the min is plotted of data in the corresponding temporal range
        % 3. Raw: Raw data at full sampling rate
        % 4. LFP: .LFP file, typically the raw data has been downpass filtered and downsampled to 1250Hz before this. All samples are shown.
        % 5. Image: Raw data displayed with the imagesc function
        % Only data thas is not currently displayed will be loaded.
        
        if UI.fid.ephys == -1 && UI.settings.plotStyle ~= 4
            return 
        end
        
        if UI.settings.greyScaleTraces < 5
            colors = UI.colors/UI.settings.greyScaleTraces;
        elseif UI.settings.greyScaleTraces >=5
            colors = ones(size(UI.colors))/(UI.settings.greyScaleTraces-4);
            colors(1:2:end,:) = colors(1:2:end,:)-0.08*(9-UI.settings.greyScaleTraces);
        end
        
        % CSD Background plot
        if UI.settings.CSD.show && numel(UI.channelOrder)>1
            plotCSD
        end
        
        if UI.settings.colorByChannels == 1
            electrodeGroupsToPlot = UI.settings.electrodeGroupsToPlot;
            channelsList = UI.channels;
            colorsList = colors;
            
        elseif UI.settings.colorByChannels == 2
            channelsList2 = UI.channelOrder;
            channelsList = {};
            temp = rem(0:numel(channelsList2)-1,UI.settings.nColorGroups)+1;
            for i = 1:max(temp)
                channelsList{i} = channelsList2(find(temp==i));
            end
            colors = eval([UI.settings.colormap,'(',num2str(numel(channelsList)),')']);
            electrodeGroupsToPlot = 1:max(temp);
            
            if UI.settings.greyScaleTraces < 5
                colors = colors/UI.settings.greyScaleTraces;
            elseif UI.settings.greyScaleTraces >=5
                colors = ones(size(colors))/(UI.settings.greyScaleTraces-4);
                colors(1:2:end,:) = colors(1:2:end,:)-0.08*(9-UI.settings.greyScaleTraces);
            end
            colorsList = colors;
        elseif UI.settings.colorByChannels == 3
            channelsList2 = UI.channelOrder;
            channelsList = {};
            nElectrodes = ceil(numel(channelsList2)/UI.settings.nColorGroups);
            electrodeGroupsToPlot = 1:nElectrodes;
            for i = 1:nElectrodes
                channelsList{i} = channelsList2((i-1)*UI.settings.nColorGroups+1:min(i*UI.settings.nColorGroups,numel(channelsList2)));
            end
            colors = eval([UI.settings.colormap,'(',num2str(nElectrodes),')']);
            
            if UI.settings.greyScaleTraces < 5
                colors = colors/UI.settings.greyScaleTraces;
            elseif UI.settings.greyScaleTraces >=5
                colors = ones(size(colors))/(UI.settings.greyScaleTraces-4);
                colors(1:2:end,:) = colors(1:2:end,:)-0.08*(9-UI.settings.greyScaleTraces);
            end
            colorsList = colors;
        end
        
        if UI.settings.plotStyle == 1 
            % Low sampled values (Faster plotting)
            for iShanks = electrodeGroupsToPlot
                channels = channelsList{iShanks};
                if ~isempty(channels)
                    timeLine = ([1:UI.nDispSamples]'/UI.nDispSamples*UI.settings.windowDuration/UI.settings.columns)*ones(1,length(channels))+UI.settings.channels_relative_offset(channels);
                    line(UI.plot_axis1,timeLine,ephys.traces(UI.dispSamples,channels)-UI.channelOffset(channels),'color',colorsList(iShanks,:), 'HitTest','off','LineWidth',UI.settings.linewidth);
                end
            end
        elseif UI.settings.plotStyle == 2 && (size(ephys.traces,1) > UI.settings.plotStyleDynamicThreshold || ~UI.settings.plotStyleDynamicRange) % Range values per sample (ala Neuroscope1)
            % Range data (low sampled values with min and max per interval)
            excess_samples = rem(size(ephys.traces,1),ceil(UI.settings.plotStyleRangeSamples*UI.settings.windowDuration));
            ephys_traces3 = ephys.traces(1:end-excess_samples,:);
            ephys_traces2 = reshape(ephys_traces3,ceil(UI.settings.plotStyleRangeSamples*UI.settings.windowDuration),[]);
            ephys.traces_min = reshape(min(ephys_traces2),[],size(ephys.traces,2));
            ephys.traces_max = reshape(max(ephys_traces2),[],size(ephys.traces,2));

            for iShanks = electrodeGroupsToPlot
                tist = [];
                timeLine = [];
                channels = channelsList{iShanks};
%                 [~,ia,~] = intersect(UI.channelOrder,channels,'stable');
                tist(1,:,:) = ephys.traces_min(:,channels)-UI.channelOffset(channels);
                tist(2,:,:) = ephys.traces_max(:,channels)-UI.channelOffset(channels);
                tist(:,end+1,:) = nan;
                timeLine1 = repmat([1:size(ephys.traces_min,1)]/size(ephys.traces_min,1)*UI.settings.windowDuration/UI.settings.columns,numel(channels),1)'+UI.settings.channels_relative_offset(channels);
                timeLine(1,:,:) = timeLine1;
                timeLine(2,:,:) = timeLine1;
                timeLine(:,end+1,:) = timeLine(:,end,:);
                line(UI.plot_axis1,timeLine(:),tist(:),'color',colorsList(iShanks,:),'LineStyle','-', 'HitTest','off','LineWidth',UI.settings.linewidth);
            end
            
        elseif UI.settings.plotStyle == 5
            % Image representation
            timeLine = [1:size(ephys.traces,1)]/size(ephys.traces,1)*UI.settings.windowDuration;
            
            if UI.settings.plotTracesInColumns
                
                for iShanks = electrodeGroupsToPlot
                    channels = channelsList{iShanks};
                    if ~isempty(channels)
                        multiplier = -UI.channelOffset(channels);
                        timeLine1 = timeLine/UI.settings.columns+UI.settings.channels_relative_offset(channels(1));
                        imagesc(UI.plot_axis1,timeLine1,multiplier,ephys.traces(:,channels)', 'HitTest','off')
                    end
                end
            else
                multiplier = [size(ephys.traces,1)-1:-1:0]/(size(ephys.traces,1)-1)*diff(UI.dataRange.ephys)+UI.dataRange.ephys(1);
                imagesc(UI.plot_axis1,timeLine,multiplier,ephys.traces(:,UI.channelOrder)', 'HitTest','off')
            end
            
        elseif UI.settings.plotStyle == 6
            % No traces
            
        else % UI.settings.plotStyle == [3,4]
            % Raw data
            timeLine = [1:size(ephys.traces,1)]'/size(ephys.traces,1)*UI.settings.windowDuration/UI.settings.columns;
            n_pieces = ceil(size(ephys.traces,1)/UI.settings.plotStyleDynamicThreshold);
            for iShanks = electrodeGroupsToPlot
                channels = channelsList{iShanks};
                if ~isempty(channels)
                    timeLine1 = timeLine*ones(1,length(channels))+UI.settings.channels_relative_offset(channels);
                    for i = 1:n_pieces
                        max_pieces = min(i*UI.settings.plotStyleDynamicThreshold,size(ephys.traces,1));
                        piece = [(i-1)*UI.settings.plotStyleDynamicThreshold+1:max_pieces];
                        line(UI.plot_axis1,timeLine1(piece),ephys.traces(piece,channels)-UI.channelOffset(channels),'color',colorsList(iShanks,:),'LineStyle','-', 'HitTest','off','LineWidth',UI.settings.linewidth)
                    end
                end
            end
        end
        
        if ~isempty(UI.settings.channelTags.highlight)
            for i = 1:numel(UI.settings.channelTags.highlight)
                channels = data.session.channelTags.(UI.channelTags{UI.settings.channelTags.highlight(i)}).channels;
                if ~isempty(channels)
                    channels = UI.channelMap(channels); channels(channels==0) = [];
                    if ~isempty(channels) && any(ismember(channels,UI.channelOrder))
                        highlightTraces(channels,UI.colors_tags(UI.settings.channelTags.highlight(i),:));
                    end
                end
            end
        end
        
        if UI.settings.stickySelection && ~isempty(UI.selectedChannels)
            for i = 1:length(UI.selectedChannels)
                if ismember(UI.selectedChannels(i), UI.channelOrder)
                    highlightTraces(UI.selectedChannels(i),UI.selectedChannelsColors(i,:));
                end
            end
        end
        
        % Detecting and plotting spikes
        if UI.settings.detectSpikes && ~isempty(UI.channelOrder)
            [UI.settings.filter.b2, UI.settings.filter.a2] = butter(3, 500/(ephys.sr/2), 'high');
            if UI.settings.removeDC
                ephys.filt = ephys.raw-mean(ephys.raw);
            else
                ephys.filt = ephys.raw;
            end
            ephys.filt(:,UI.channelOrder) = filtfilt(UI.settings.filter.b2, UI.settings.filter.a2, ephys.filt(:,UI.channelOrder));
            
            raster = [];
            raster.idx = [];
            raster.x = [];
            raster.times = [];
            raster.y = [];
            raster.channel = [];
            
            for i = 1:numel(UI.channelOrder)
                if UI.settings.spikesDetectionPolarity
                    idx = find(diff(ephys.filt(:,UI.channelOrder(i)) < -abs(UI.settings.spikesDetectionThreshold))==1 | diff(ephys.filt(:,UI.channelOrder(i)) > abs(UI.settings.spikesDetectionThreshold))==1)+1;
                elseif UI.settings.spikesDetectionThreshold>0
                    idx = find(diff(ephys.filt(:,UI.channelOrder(i)) > UI.settings.spikesDetectionThreshold)==1)+1;
                else                    
                    idx = find(diff(ephys.filt(:,UI.channelOrder(i)) < UI.settings.spikesDetectionThreshold)==1)+1;
                end
                
                if ~isempty(idx)
                    raster.times = [raster.times;idx/ephys.sr];
                    raster.idx = [raster.idx;idx];
%                     raster.x = [raster.x;idx/ephys.sr/UI.settings.columns+UI.settings.channels_relative_offset(raster.channel)'];
                    raster.channel = [raster.channel;UI.channelOrder(i)*ones(size(idx))];
                    if UI.settings.detectedSpikesBelowTrace
                        raster.x = [raster.x;idx/ephys.sr];
                        raster_y = diff(UI.dataRange.detectedSpikes)*(-UI.channelScaling(idx,UI.channelOrder(i)))+UI.dataRange.detectedSpikes(1)+0.004;
                        raster.y = [raster.y;raster_y];
                    elseif any(UI.settings.plotStyle == [5,6])
                        raster.x = [raster.x;idx/ephys.sr/UI.settings.columns+UI.settings.channels_relative_offset(UI.channelOrder(i)*ones(size(idx)))'];
                        raster.y = [raster.y;-UI.channelScaling(idx,UI.channelOrder(i))];
                    else
                        raster.x = [raster.x;idx/ephys.sr/UI.settings.columns+UI.settings.channels_relative_offset(UI.channelOrder(i)*ones(size(idx)))'];
                        raster.y = [raster.y;ephys.traces(idx,UI.channelOrder(i))-UI.channelScaling(idx,UI.channelOrder(i))];
                    end
                end
            end
            
            % Removing artifacts (spike events detected on more than a quater the channels within 1 ms bins (min 20 channels))
%             [~,idxu,idxc] = unique(raster.idx); % Unique values
            [count, ~, idxcount] = histcounts(raster.x*1000,[0:UI.settings.windowDuration*1000]); % count unique values
            idx2remove = count(idxcount)>max([20,numel(UI.channelOrder)/4]); % Finding timepoints to remove
            raster.idx(idx2remove) = [];
            raster.x(idx2remove) = [];
            raster.y(idx2remove) = []; 
            raster.channel(idx2remove) = [];
            raster.times(idx2remove) = [];
            
            % Showing waveforms of detected spikes
            if UI.settings.showDetectedSpikeWaveforms
                if UI.settings.colorDetectedSpikesByWidth
                    raster = plotSpikeWaveforms(raster,UI.settings.primaryColor,5);
                else
                    plotSpikeWaveforms(raster,UI.settings.primaryColor,2);
                end
            end
            
            % Showing waveforms of detected spikes
            if UI.settings.showDetectedSpikesPopulationRate                
                if UI.settings.showPopulationRate
                    clr1 = UI.settings.primaryColor*0.6;
                else
                    clr1 = UI.settings.primaryColor;
                end
                if UI.settings.colorDetectedSpikesByWidth
                    plotPopulationRate(raster,clr1,5);
                else
                    plotPopulationRate(raster,clr1,2);
                end
                addLegend('Population rate of detected spikes',clr1)
            end
            
            if UI.settings.showSpikes && ~UI.settings.detectedSpikesBelowTrace
                markerType = 'o';
            else
                markerType = UI.settings.rasterMarker;
            end
            
            % Plotting spike rasters
            if UI.settings.showDetectedSpikeWaveforms && UI.settings.colorDetectedSpikesByWidth
                raster.spike_identity;
                unique_electrodeGroups = unique(raster.spike_identity);
                spike_identity_colormap = [0.2 0.2 1; 1 0.2 0.2];
                for i = 1:numel(unique_electrodeGroups)
                    idx_uids = raster.spike_identity == i;
                    line(UI.plot_axis1,raster.x(idx_uids), raster.y(idx_uids),'Marker',markerType,'LineStyle','none','color',spike_identity_colormap(unique_electrodeGroups(i),:), 'HitTest','off','linewidth',UI.settings.spikeRasterLinewidth);
                end
            else
                line(UI.plot_axis1,raster.x, raster.y,'Marker',markerType,'LineStyle','none','color',UI.settings.primaryColor, 'HitTest','off','linewidth',UI.settings.spikeRasterLinewidth);
            end
            
        end
        
        % Detecting and plotting events
        if UI.settings.detectEvents && ~isempty(UI.channelOrder)
            raster = [];
            raster.x = [];
            raster.y = [];
%             for i = 1:size(ephys.traces,2)
            for i = 1:numel(UI.channelOrder)
                if UI.settings.eventThreshold>0
                    idx = find(diff(ephys.traces(:,UI.channelOrder(i))/(UI.settings.scalingFactor/1000000) > UI.settings.eventThreshold)==1);
                else
                    idx = find(diff(ephys.traces(:,UI.channelOrder(i))/(UI.settings.scalingFactor/1000000) < UI.settings.eventThreshold)==1);
                end
                if ~isempty(idx)
%                     raster.x = [raster.x;idx];
                    
                    if UI.settings.detectedEventsBelowTrace
                        raster.x = [raster.x;idx/ephys.sr];
                        raster_y = diff(UI.dataRange.detectedEvents)*(-UI.channelScaling(idx,UI.channelOrder(i)))+UI.dataRange.detectedEvents(1)+0.004;
                        raster.y = [raster.y;raster_y];
                    elseif any(UI.settings.plotStyle == [5,6])
                        raster.x = [raster.x;idx/ephys.sr];
                        raster.y = [raster.y;-UI.channelScaling(idx,UI.channelOrder(i))];    
                    else
                        raster.x = [raster.x;idx/ephys.sr/UI.settings.columns+UI.settings.channels_relative_offset(UI.channelOrder(i)*ones(size(idx)))'];
                        raster.y = [raster.y;ephys.traces(idx,UI.channelOrder(i))-UI.channelScaling(idx,UI.channelOrder(i))];
                    end
                end
            end
            
            line(UI.plot_axis1,raster.x, raster.y,'Marker',UI.settings.rasterMarker,'LineStyle','none','color','m', 'HitTest','off');
        end
        
        % Plotting channel numbers
        if UI.settings.showChannelNumbers
            text(UI.plot_axis1,zeros(1,numel(UI.channelOrder))+UI.settings.channels_relative_offset(UI.channelOrder),-UI.channelOffset(UI.channelOrder),strcat(cellstr(num2str(UI.channelOrder')),{' '}),'color',UI.settings.primaryColor,'VerticalAlignment', 'middle','HorizontalAlignment','right','HitTest','off')
        end
        
        % Plotting scale bar
        if UI.settings.showScalebar
            plot(UI.plot_axis1,[0.005,0.005],[0.93,0.98],'-','linewidth',3,'color',UI.settings.primaryColor)
            text(UI.plot_axis1,0.005,0.955,['  ',num2str(0.05/(UI.settings.scalingFactor)*1000,3),' mV'],'FontWeight', 'Bold','VerticalAlignment', 'middle','HorizontalAlignment','left','color',UI.settings.primaryColor)
        end

        % Plotting timescale bar
        if UI.settings.showTimeScalebar
            plot(UI.plot_axis1,[0.94,0.99]*UI.settings.windowDuration,[0.01,0.01],'-','linewidth',3,'color',UI.settings.primaryColor)
            if UI.settings.windowDuration < 20
                text(UI.plot_axis1,0.965*UI.settings.windowDuration,0.011,['  ',num2str(0.05*(UI.settings.windowDuration)*1000,3),' msec'],'FontWeight', 'Bold','VerticalAlignment', 'bottom','HorizontalAlignment','center','color',UI.settings.primaryColor)
            else
                text(UI.plot_axis1,0.965*UI.settings.windowDuration,0.011,['  ',num2str(0.05*(UI.settings.windowDuration),3),' sec'],'FontWeight', 'Bold','VerticalAlignment', 'bottom','HorizontalAlignment','center','color',UI.settings.primaryColor)
            end
        end
        ephys.plotted = true;
    end

    function plotAnalog(signal)
        sr = data.session.timeSeries.(signal).sr;
        precision = data.session.timeSeries.(signal).precision;
        nDispSamples = UI.settings.windowDuration*sr;
        % Plotting analog traces
        if strcmp(UI.settings.fileRead,'bof')
            fseek(UI.fid.timeSeries.(signal),round(UI.t0*sr)*data.session.timeSeries.(signal).nChannels*2,'bof'); % eof: end of file
        else 
            fseek(UI.fid.timeSeries.(signal),ceil(-UI.settings.windowDuration*sr)*data.session.timeSeries.(signal).nChannels*2,'eof'); % eof: end of file
        end
        traces_analog = fread(UI.fid.timeSeries.(signal), [data.session.timeSeries.(signal).nChannels, nDispSamples],precision)';
        if UI.settings.showTimeseriesBelowTrace
            line(UI.plot_axis1,(1:nDispSamples)/sr,traces_analog./2^16*diff(UI.dataRange.intan)+UI.dataRange.intan(1), 'HitTest','off','Marker','none','LineStyle','-','linewidth',1);
        else
            line(UI.plot_axis1,(1:nDispSamples)/sr,traces_analog./2^16, 'HitTest','off','Marker','none','LineStyle','-','linewidth',1.5);
        end
        addLegend(['Analog timeseries: ' signal])
        for i = 1:data.session.timeSeries.(signal).nChannels
            addLegend(strrep(UI.settings.traceLabels.(signal){i}, '_', ' '),UI.colorLine(i,:));
        end
    end

    function plotDigital(signal)
        sr = data.session.timeSeries.(signal).sr;
        precision = data.session.timeSeries.(signal).precision;
        nDispSamples = UI.settings.windowDuration*sr;
        
        % Plotting digital traces
        if strcmp(UI.settings.fileRead,'bof')
            fseek(UI.fid.timeSeries.(signal),round(UI.t0*sr)*2,'bof');
        else
            fseek(UI.fid.timeSeries.(signal),ceil(-UI.settings.windowDuration*sr)*2,'eof');
        end
        traces_digital = fread(UI.fid.timeSeries.(signal), nDispSamples,precision)';
        traces_digital2 = [];
        for i = 1:data.session.timeSeries.(signal).nChannels
            traces_digital2(:,i) = bitget(traces_digital,i)+i*0.001;
        end
        if UI.settings.showTimeseriesBelowTrace
            line(UI.plot_axis1,(1:nDispSamples)/sr,0.98*traces_digital2*diff(UI.dataRange.intan)+UI.dataRange.intan(1)+0.004, 'HitTest','off','Marker','none','LineStyle','-');
        else
            line(UI.plot_axis1,(1:nDispSamples)/sr,0.98*traces_digital2+0.005, 'HitTest','off','Marker','none','LineStyle','-');
        end
        addLegend(['Digital timeseries: ' signal])
        for i = 1:data.session.timeSeries.(signal).nChannels
            addLegend(UI.settings.traceLabels.(signal){i},UI.colorLine(i,:)*0.8);
        end
    end

    function highlightTraces(channels,colorIn)
        % Highlight ephys channel(s)
        if ~isempty(colorIn)
            colorLine = colorIn;
        else
            UI.iLine = mod(UI.iLine,7)+1;
            colorLine = UI.colorLine(UI.iLine,:);
        end
        
        if ~isempty(UI.channelOrder)
            if UI.settings.plotStyle == 1
                line(UI.plot_axis1,[1:UI.nDispSamples]/UI.nDispSamples*UI.settings.windowDuration,ephys.traces(UI.dispSamples,channels)-UI.channelOffset(channels), 'HitTest','off','linewidth',1.2,'color',colorLine);
            elseif UI.settings.plotStyle == 2 && (size(ephys.traces,1) > UI.settings.plotStyleDynamicThreshold || ~UI.settings.plotStyleDynamicRange)
                tist = [];
                timeLine = [];
                tist(1,:,:) = ephys.traces_min(:,channels)-UI.channelOffset(channels);
                tist(2,:,:) = ephys.traces_max(:,channels)-UI.channelOffset(channels);
                tist(:,end+1,:) = nan;
%                 timeLine1 = repmat([1:size(ephys.traces_min,1)]/size(ephys.traces_min,1)*UI.settings.windowDuration,numel(channels),1)';
                timeLine1 = repmat([1:size(ephys.traces_min,1)]/size(ephys.traces_min,1)*UI.settings.windowDuration/UI.settings.columns,numel(channels),1)'+UI.settings.channels_relative_offset(channels);
                timeLine(1,:,:) = timeLine1;
                timeLine(2,:,:) = timeLine1;
                timeLine(:,end+1,:) = timeLine(:,end,:);
                line(UI.plot_axis1,timeLine(:)',tist(:)','LineStyle','-', 'HitTest','off','linewidth',1.2,'color',colorLine);
            else
                timeLine = [1:size(ephys.traces,1)]'/size(ephys.traces,1)*UI.settings.windowDuration/UI.settings.columns;
                timeLine1 = timeLine*ones(1,length(channels))+UI.settings.channels_relative_offset(channels);
                line(UI.plot_axis1,timeLine1,ephys.traces(:,channels)-UI.channelOffset(channels),'LineStyle','-', 'HitTest','off','linewidth',1.2,'color',colorLine);
            end
        end
    end

    function plotBehavior(t1,t2,colorIn)
        % Plots behavior
        idx = find((data.behavior.(UI.settings.behaviorData).timestamps > t1 & data.behavior.(UI.settings.behaviorData).timestamps < t2));
        if ~isempty(idx)
            % PLots behavior data on top of the ephys
            if UI.settings.plotBehaviorLinearized & isfield(data.behavior.(UI.settings.behaviorData).position,'linearized')
                if UI.settings.showBehaviorBelowTrace
                    line(data.behavior.(UI.settings.behaviorData).timestamps(idx)-t1,data.behavior.(UI.settings.behaviorData).position.linearized(idx)/data.behavior.(UI.settings.behaviorData).limits.linearized(2)*diff(UI.dataRange.behavior)+UI.dataRange.behavior(1), 'Color', colorIn, 'HitTest','off','Marker','.','LineStyle','-','linewidth',2)
                else
                    line(data.behavior.(UI.settings.behaviorData).timestamps(idx)-t1,data.behavior.(UI.settings.behaviorData).position.linearized(idx)/data.behavior.(UI.settings.behaviorData).limits.linearized(2), 'Color', colorIn, 'HitTest','off','Marker','.','LineStyle','-','linewidth',2)
                end
            else
                % Shows behavior data in a small inset plot in the lower right corner
                p1 = patch([5*(t2-t1)/6,(t2-t1),(t2-t1),5*(t2-t1)/6]-0.01,[0 0 0.25 0.25]+0.01+UI.ephys_offset,'k','HitTest','off','EdgeColor',[0.5 0.5 0.5]);
                alpha(p1,0.4);
                line((data.behavior.(UI.settings.behaviorData).position.x(idx)-data.behavior.(UI.settings.behaviorData).limits.x(1))/diff(data.behavior.(UI.settings.behaviorData).limits.x)*(t2-t1)/6+5*(t2-t1)/6-0.01,(data.behavior.(UI.settings.behaviorData).position.y(idx)-data.behavior.(UI.settings.behaviorData).limits.y(1))/diff(data.behavior.(UI.settings.behaviorData).limits.y)*0.25+0.01+UI.ephys_offset, 'Color', colorIn, 'HitTest','off','Marker','none','LineStyle','-','linewidth',2)
                idx2 = [idx(1),idx(round(end/4)),idx(round(end/2)),idx(round(3*end/4))];
                line((data.behavior.(UI.settings.behaviorData).position.x(idx2)-data.behavior.(UI.settings.behaviorData).limits.x(1))/diff(data.behavior.(UI.settings.behaviorData).limits.x)*(t2-t1)/6+5*(t2-t1)/6-0.01,(data.behavior.(UI.settings.behaviorData).position.y(idx2)-data.behavior.(UI.settings.behaviorData).limits.y(1))/diff(data.behavior.(UI.settings.behaviorData).limits.y)*0.25+0.01+UI.ephys_offset, 'Color', [0.9,0.5,0.9], 'HitTest','off','Marker','o','LineStyle','none','linewidth',0.5,'MarkerFaceColor',[0.9,0.5,0.9],'MarkerEdgeColor',[0.9,0.5,0.9]);
                line((data.behavior.(UI.settings.behaviorData).position.x(idx(end))-data.behavior.(UI.settings.behaviorData).limits.x(1))/diff(data.behavior.(UI.settings.behaviorData).limits.x)*(t2-t1)/6+5*(t2-t1)/6-0.01,(data.behavior.(UI.settings.behaviorData).position.y(idx(end))-data.behavior.(UI.settings.behaviorData).limits.y(1))/diff(data.behavior.(UI.settings.behaviorData).limits.y)*0.25+0.01+UI.ephys_offset, 'Color', [1,0.7,1], 'HitTest','off','Marker','s','LineStyle','none','linewidth',0.5,'MarkerFaceColor',[1,0.7,1],'MarkerEdgeColor',[1,0.7,1]);
                
                % Showing spikes in the 2D behavior plot
                if UI.settings.showSpikes && ~isempty(spikes_raster)
                    if UI.settings.spikesGroupColors == 4
                        % UI.params.sortingMetric = 'putativeCellType';
                        putativeCellTypes = unique(data.cell_metrics.(UI.params.groupMetric));
%                         UI.colors_metrics = hsv(numel(putativeCellTypes));
                        UI.colors_metrics = eval([UI.settings.spikesColormap,'(',num2str(numel(putativeCellTypes)),')']);
                        k = 1;
                        for i = 1:numel(putativeCellTypes)
                            idx2 = find(ismember(data.cell_metrics.(UI.params.groupMetric),putativeCellTypes{i}));
                            idx3 = ismember(spikes_raster.UID,idx2);
                            if any(idx3)
                                plotBehaviorEvents(spikes_raster.x(idx3)+t1,UI.colors_metrics(i,:),'o');
                                k = k+1;
                            end
                        end
                    elseif UI.settings.spikesGroupColors == 1
%                         uid = data.spikes.spindices(spikes_raster.spin_idx,2);
                        unique_uids = unique(spikes_raster.UID);
                        uid_colormap = eval([UI.settings.spikesColormap,'(',num2str(numel(unique_uids)),')']);
                        for i = 1:numel(unique_uids)
                            idx_uids = spikes_raster.UID == unique_uids(i);
                            plotBehaviorEvents(spikes_raster.x(idx_uids)+t1,uid_colormap(i,:),'o')
                        end
                    elseif UI.settings.spikesGroupColors == 3
                        unique_electrodeGroups = unique(spikes_raster.electrodeGroup)';
                        electrodeGroup_colormap = UI.colors;
                        for i = unique_electrodeGroups
                            idx_uids = spikes_raster.electrodeGroup' == i;
                            plotBehaviorEvents(spikes_raster.x(idx_uids)+t1,electrodeGroup_colormap(i,:),'o')
                        end
                    else
                        plotBehaviorEvents(spikes_raster.x+t1,UI.settings.primaryColor,'o')
                    end
                end
                
                % Showing events in the 2D behavior plot
                if any(UI.settings.showEvents)
                    idx = find(data.events.(UI.settings.eventData).time >= t1 & data.events.(UI.settings.eventData).time <= t2);
                    % Plotting flagged events in a different color
                    if isfield(data.events.(UI.settings.eventData),'flagged')
                        idx2 = ismember(idx,data.events.(UI.settings.eventData).flagged);
                        if any(idx2)
                            plotBehaviorEvents(data.events.(UI.settings.eventData).time(idx(idx2)),'m','s')
                        end
                        idx(idx2) = [];
                    end
                    % Plotting events
                    if any(idx)
                        plotBehaviorEvents(data.events.(UI.settings.eventData).time(idx),colorIn,'s')
                    end
                    
                    % Plotting added events
                    if isfield(data.events.(UI.settings.eventData),'added') && ~isempty(isfield(data.events.(UI.settings.eventData),'added'))
                        idx3 = find(data.events.(UI.settings.eventData).added >= t1 & data.events.(UI.settings.eventData).added <= t2);
                        if any(idx3)
                            plotBehaviorEvents(data.events.(UI.settings.eventData).added(idx3),'c','s')
                        end
                    end
                end
            end
        end
        
        function plotBehaviorEvents(timestamps,markerColor,markerStyle)
            pos_x = interp1(data.behavior.(UI.settings.behaviorData).timestamps,data.behavior.(UI.settings.behaviorData).position.x,timestamps);
            pos_y = interp1(data.behavior.(UI.settings.behaviorData).timestamps,data.behavior.(UI.settings.behaviorData).position.y,timestamps);
            line((pos_x-data.behavior.(UI.settings.behaviorData).limits.x(1))/diff(data.behavior.(UI.settings.behaviorData).limits.x)*(t2-t1)/6+5*(t2-t1)/6-0.01,(pos_y-data.behavior.(UI.settings.behaviorData).limits.y(1))/diff(data.behavior.(UI.settings.behaviorData).limits.y)*0.25+0.01+UI.ephys_offset, 'Color', [markerColor,0.5],'Marker',markerStyle,'LineStyle','none','linewidth',1,'MarkerFaceColor',markerColor,'MarkerEdgeColor',markerColor, 'HitTest','off');
        end
    end

    function plotSpikeData(t1,t2,colorIn,axesIn)
        % Plots spikes
        
        % Determining which units to plot from various filters
        units2plot = [find(ismember(data.spikes.maxWaveformCh1,[UI.channels{UI.settings.electrodeGroupsToPlot}])),UI.params.subsetTable,UI.params.subsetCellType,UI.params.subsetFilter,UI.params.subsetGroups];
        units2plot = find(histcounts(units2plot,1:data.spikes.numcells+1)==5);
        
        % Finding the spikes in the spindices to plot by index
        spin_idx = find(data.spikes.spindices(:,1) > t1 & data.spikes.spindices(:,1) < t2);
        spin_idx = spin_idx(ismember(data.spikes.spindices(spin_idx,2),units2plot));
        
        spikes_raster = [];
        if any(spin_idx)
            spikes_raster.times = data.spikes.spindices(spin_idx,1)-t1;
            spikes_raster.UID = data.spikes.spindices(spin_idx,2);
            if isfield(data.spikes,'shankID')
                spikes_raster.electrodeGroup = data.spikes.shankID(spikes_raster.UID)';
            end
            spikes_raster.channel = data.spikes.maxWaveformCh1(data.spikes.spindices(spin_idx,2))';
            
            if UI.settings.spikesBelowTrace
                spikes_raster.x = spikes_raster.times;
                spikes_raster.idx = round(spikes_raster.x*ephys.sr);
                if UI.settings.useSpikesYData
                    spikes_raster.y = (diff(UI.dataRange.spikes))*((data.spikes.spindices(spin_idx,3)-UI.settings.spikes_ylim(1))/diff(UI.settings.spikes_ylim))+UI.dataRange.spikes(1)+0.004;
                else
                    if UI.settings.useMetrics
                        if iscell(data.cell_metrics.(UI.params.sortingMetric))
                            [~,sortIdx] = sort(data.cell_metrics.(UI.params.sortingMetric));
                            if strcmp(UI.settings.reverseSpikeSorting,'descend')
                                sortIdx = flipud(fliplr(sortIdx));
                            end
                            [~,sortIdx] = sort(sortIdx);
                        else
                            [~,sortIdx] = sort(data.cell_metrics.(UI.params.sortingMetric),UI.settings.reverseSpikeSorting);
                            [~,sortIdx] = sort(sortIdx);
                        end
                    else
                        sortIdx = sort(1:data.spikes.numcells,UI.settings.reverseSpikeSorting);
                    end
                    spikes_raster.y = (diff(UI.dataRange.spikes))*(sortIdx(data.spikes.spindices(spin_idx,2))/(data.spikes.numcells))+UI.dataRange.spikes(1)+0.004;
                end
            else
                spikes_raster.x = (data.spikes.spindices(spin_idx,1)-t1)/UI.settings.columns+UI.settings.channels_relative_offset(spikes_raster.channel)';
                spikes_raster.idx = round(spikes_raster.times*ephys.sr);
                
                % Aligning timestamps and determining trace value for each spike
                if UI.settings.plotStyle == 1
                    idx2 = round(spikes_raster.times*UI.nDispSamples/UI.settings.windowDuration);
                    idx2(idx2==0)= 1; % realigning spikes events outside a low sampled trace
                    traces = ephys.traces(UI.dispSamples,:)-UI.channelOffset;
                    idx3 = sub2ind(size(traces),idx2,spikes_raster.channel);
                    spikes_raster.y = traces(idx3);
                    
                elseif UI.settings.plotStyle == 2 && (size(ephys.traces,1) > UI.settings.plotStyleDynamicThreshold || ~UI.settings.plotStyleDynamicRange)
                    idx2 = round(spikes_raster.times*size(ephys.traces_min,1)/UI.settings.windowDuration);
                    idx2(idx2==0)= 1; % realigning spikes events outside a low sampled trace
                    traces = ephys.traces_min-UI.channelOffset;
                    idx3 = sub2ind(size(traces),idx2,spikes_raster.channel);
                    spikes_raster.y = traces(idx3);
                elseif any(UI.settings.plotStyle == [5,6])
                    idx2 = round(spikes_raster.times*size(ephys.traces,1)/UI.settings.windowDuration);
                    idx2(idx2==0)= 1; % realigning spikes events outside a low sampled trace
                    idx3 = sub2ind(size(ephys.traces),idx2,spikes_raster.channel);
                    spikes_raster.y = -UI.channelScaling(idx3);
                else
                    idx2 = round(spikes_raster.times*size(ephys.traces,1)/UI.settings.windowDuration);
                    idx2(idx2==0)= 1; % realigning spikes events outside a low sampled trace
                    idx3 = sub2ind(size(ephys.traces),idx2,spikes_raster.channel);
                    spikes_raster.y = ephys.traces(idx3)-UI.channelScaling(idx3);
                end
            end
             
            if UI.settings.spikesGroupColors == 4
                putativeCellTypes = unique(data.cell_metrics.(UI.params.groupMetric));
                UI.colors_metrics = eval([UI.settings.spikesColormap,'(',num2str(numel(putativeCellTypes)),')']);

                addLegend(['Cell metrics: ' UI.params.groupMetric])
                for i = 1:numel(putativeCellTypes)
                    idx2 = find(ismember(data.cell_metrics.(UI.params.groupMetric),putativeCellTypes{i}));
                    idx3 = ismember(data.spikes.spindices(spin_idx,2),idx2);
                    if any(idx3)
                        line(axesIn,spikes_raster.x(idx3), spikes_raster.y(idx3),'Marker',UI.settings.rasterMarker,'LineStyle','none','color',UI.colors_metrics(i,:), 'HitTest','off','linewidth',UI.settings.spikeRasterLinewidth);
                        addLegend(putativeCellTypes{i},UI.colors_metrics(i,:)*0.8);
                    end
                end

            elseif UI.settings.spikesGroupColors == 1
                uid = data.spikes.spindices(spin_idx,2);
                unique_uids = unique(uid);
                uid_colormap = eval([UI.settings.spikesColormap,'(',num2str(numel(unique_uids)),')']);
                for i = 1:numel(unique_uids)
                    idx_uids = uid == unique_uids(i);
                    line(axesIn,spikes_raster.x(idx_uids), spikes_raster.y(idx_uids),'Marker',UI.settings.rasterMarker,'LineStyle','none','color',uid_colormap(i,:), 'HitTest','off','linewidth',UI.settings.spikeRasterLinewidth);
                end
            elseif UI.settings.spikesGroupColors == 3
                unique_electrodeGroups = unique(spikes_raster.electrodeGroup);
                electrodeGroup_colormap = UI.colors;
                for i = 1:numel(unique_electrodeGroups)
                    idx_uids = spikes_raster.electrodeGroup == unique_electrodeGroups(i);
                    line(axesIn,spikes_raster.x(idx_uids), spikes_raster.y(idx_uids),'Marker',UI.settings.rasterMarker,'LineStyle','none','color',electrodeGroup_colormap(unique_electrodeGroups(i),:), 'HitTest','off','linewidth',UI.settings.spikeRasterLinewidth);
                end
            else
                line(axesIn,spikes_raster.x, spikes_raster.y,'Marker',UI.settings.rasterMarker,'LineStyle','none','color',colorIn, 'HitTest','off','linewidth',UI.settings.spikeRasterLinewidth);
            end
            
            % Highlights cells ('tags','groups','groundTruthClassification')
            if ~isempty(UI.groupData1)
                uids_toHighlight = [];
                dataTypes = {'tags','groups','groundTruthClassification'};
                for jjj = 1:numel(dataTypes)
                    if isfield(UI.groupData1,dataTypes{jjj}) && isfield(UI.groupData1.(dataTypes{jjj}),'highlight')
                        fields1 = fieldnames(UI.groupData1.(dataTypes{jjj}).highlight);
                        for jj = 1:numel(fields1)
                            if UI.groupData1.(dataTypes{jjj}).highlight.(fields1{jj}) == 1 && ~isempty(data.cell_metrics.(dataTypes{jjj}).(fields1{jj})) && any(ismember(units2plot,data.cell_metrics.(dataTypes{jjj}).(fields1{jj})))
                                idx_groupData1 = intersect(units2plot,data.cell_metrics.(dataTypes{jjj}).(fields1{jj}));
                                uids_toHighlight = [uids_toHighlight,idx_groupData1];
                            end
                        end
                    end
                end
                if ~isempty(uids_toHighlight)
                    highlightUnits(unique(uids_toHighlight),[]);
                end
            end
            
            if UI.settings.stickySelection && ~isempty(UI.selectedUnits)
                for i = 1:length(UI.selectedUnits)
                    highlightUnits(UI.selectedUnits(i),UI.selectedUnitsColors(i,:));
                end
            end
            
            % Population rate
            if UI.settings.showPopulationRate
                plotPopulationRate(spikes_raster,UI.settings.primaryColor,UI.settings.spikesGroupColors);
                addLegend('Population rate',UI.settings.primaryColor)
            end
            
            if UI.settings.showSpikeWaveforms
                plotSpikeWaveforms(spikes_raster,UI.settings.primaryColor,UI.settings.spikesGroupColors);
            end
            
            % Showing detected spikes in a spike-waveform-PCA plot inset
            if UI.settings.showSpikesPCAspace
                if ~UI.settings.showDetectedSpikesPCAspace
                    drawBackground = true;
                else
                    drawBackground = false;
                end                    
                plotSpikesPCAspace(spikes_raster,[0.5 0.5 1],drawBackground)
            end
            
            if UI.settings.showSpikeMatrix
                plotSpikeMatrix
            end
        end
    end

    function plotSpikeMatrix
        t1 = UI.t0;
        t2 = UI.t0+UI.settings.windowDuration;
        idx = ismember(data.spikes.spindices(:,2),UI.params.subsetTable ) & ismember(data.spikes.spindices(:,2),UI.params.subsetCellType) & ismember(data.spikes.spindices(:,2),UI.params.subsetFilter) & ismember(data.spikes.spindices(:,2),UI.params.subsetGroups)  & data.spikes.spindices(:,1) > t1 & data.spikes.spindices(:,1) < t2;
        if any(idx)
            abc = histcounts(data.spikes.spindices(idx,2),1:data.spikes.numcells+1);
            plotRows = numSubplots(data.spikes.numcells);
            cell_spikematrix = zeros(1,plotRows(1)*plotRows(2));
            cell_spikematrix(1:data.spikes.numcells) = abc;
            cell_spikematrix = fliplr(reshape(cell_spikematrix,plotRows(2),plotRows(1)))';
            
            p1 = patch(UI.plot_axis1,[(1-UI.settings.insetRelativeWidth)*UI.settings.windowDuration,UI.settings.windowDuration,UI.settings.windowDuration,(1-UI.settings.insetRelativeWidth)*UI.settings.windowDuration]-0.005,[(1-UI.settings.insetRelativeHeight) (1-UI.settings.insetRelativeHeight) 1 1]-0.015,'k','HitTest','off','EdgeColor',[0.5 0.5 0.5]);
            alpha(p1,0.6);
                
            h = imagesc(UI.plot_axis1,[0.5:plotRows(2)]/plotRows(2)*UI.settings.insetRelativeWidth*UI.settings.windowDuration+(0.995-UI.settings.insetRelativeWidth)*UI.settings.windowDuration,[0.5:plotRows(1)]/plotRows(1)*UI.settings.insetRelativeHeight+(0.985-UI.settings.insetRelativeHeight),cell_spikematrix, 'AlphaData', .8);
            set(h, 'AlphaData', cell_spikematrix) 
            % Drawing PCA values
%             xlim1 = [min(abc(:,1)),max(abc(:,1))];
%             ylim1 = [min(abc(:,2)),max(abc(:,2))];
%             line(UI.plot_axis1,(abc(:,1)-xlim1(1))/diff(xlim1)*UI.settings.insetRelativeWidth*UI.settings.windowDuration+(1-UI.settings.insetRelativeWidth)*UI.settings.windowDuration-0.005,(abc(:,2)-ylim1(1))/diff(ylim1)*UI.settings.insetRelativeHeight+(0.985-UI.settings.insetRelativeHeight), 'HitTest','off','Color', lineColor,'Marker','o','LineStyle','none','linewidth',2,'MarkerFaceColor',lineColor,'MarkerEdgeColor',lineColor)
        end
    end

    function raster = plotSpikeWaveforms(raster,lineColor,plotStyle)
        
%         wfWin_sec =  0.0008; % Default: 2*0.8ms window size
        wfWin_sec = UI.settings.spikeWaveformWidth;
        wfWin = round(wfWin_sec * ephys.sr); % Windows size in sample
        
        % Removing spikes around the borders
        indexes = raster.times<=wfWin_sec | raster.times>=UI.settings.windowDuration-wfWin_sec;
        raster.channel(indexes)=[];
        raster.idx(indexes)=[];
        if isfield(raster,'UID')
            raster.UID(indexes)=[];
        end
        if isfield(raster,'electrodeGroup')
            raster.electrodeGroup(indexes)=[];
        end
        if isfield(raster,'x')
            raster.x(indexes)=[];
        end
        if isfield(raster,'y')
            raster.y(indexes)=[];
        end
        raster.times(indexes)=[];

        channels_with_spikes = unique(raster.channel);
        chanCoords_x = data.session.extracellular.chanCoords.x(UI.channelOrder(:));
        chanCoords_x = (chanCoords_x-min(chanCoords_x))/range(chanCoords_x);
        chanCoords_y = data.session.extracellular.chanCoords.y(UI.channelOrder(:));
        chanCoords_y = (chanCoords_y-min(chanCoords_y))/range(chanCoords_y);
        [~,Locb] = ismember(channels_with_spikes,UI.channelOrder(:));
        
        waveforms = zeros(wfWin*2,numel(raster.channel));
        waveforms_xdata = zeros(wfWin*2,numel(raster.channel));
        for j = 1:numel(channels_with_spikes)
            i = channels_with_spikes(j);
            timestamps = round(raster.times(raster.channel==i) * ephys.sr);
            
            if ~isempty(timestamps)
                startIndicies2 = (timestamps - wfWin)+1;
                stopIndicies2 = (timestamps + wfWin);
                X2 = cumsum(accumarray(cumsum([1;stopIndicies2(:)-startIndicies2(:)+1]),[startIndicies2(:);0]-[0;stopIndicies2(:)]-1)+1);
                if plotStyle == 5 && ~UI.settings.filterTraces
                    ephys_data = ephys.filt(:,i)';
                else                   
                    ephys_data = (1000000/UI.settings.scalingFactor)*ephys.traces(:,i)';
                end
                
                wf = reshape(double(ephys_data(X2(1:end-1))),1,(wfWin*2),[]);
                wf2 = reshape(permute(wf,[2,1,3]),(wfWin*2),[]);
                
                if UI.settings.showWaveformsBelowTrace
                    x_offset = (0.01+UI.settings.waveformsRelativeWidth/2+(0.98-UI.settings.waveformsRelativeWidth)*chanCoords_x(Locb(j)))*UI.settings.windowDuration;
                    y_offset = 0.029+UI.dataRange.spikeWaveforms(1)+(diff(UI.dataRange.spikeWaveforms)-0.05)*chanCoords_y(Locb(j));
                else
                    x_offset = 0.005*UI.settings.windowDuration;
                    y_offset = -UI.channelScaling(1,UI.channelOrder(i));
                end
                if ~isempty(wf2)
                    waveforms_xdata(:,raster.channel==i) = repmat([-wfWin+1:wfWin]/(2*wfWin)*UI.settings.waveformsRelativeWidth*UI.settings.windowDuration,size(wf2,2),1)'+x_offset;
                    waveforms(:,raster.channel==i) = ((wf2-mean(wf2)) * (UI.settings.scalingFactor)/1000000)+y_offset;
                end
            end
        end
        
        % Pulling waveforms
        if ~isempty(waveforms)
            % Drawing background
            if ~UI.settings.showWaveformsBelowTrace
                p1 = patch(UI.plot_axis1,[0.001,0.002+UI.settings.waveformsRelativeWidth*UI.settings.windowDuration,0.002+UI.settings.waveformsRelativeWidth*UI.settings.windowDuration,0.001]+0.005,[0.02 0.02 1 1]-0.01,'k','HitTest','off','EdgeColor',[0.5 0.5 0.5]);
                alpha(p1,0.6);
            end
            
            % Drawing waveforms
            if plotStyle == 1 % UID
                raster.UID(raster.times<=wfWin_sec | raster.times>=UI.settings.windowDuration-wfWin_sec)=[];
                uid = raster.UID;
                unique_uids = unique(uid);
                uid_colormap = eval([UI.settings.spikesColormap,'(',num2str(numel(unique_uids)),')']);
                for i = 1:numel(unique_uids)
                    idx_uids = uid == unique_uids(i);
                    xdata = [waveforms_xdata(:,idx_uids);nan(1,sum(idx_uids))];
                    ydata = [waveforms(:,idx_uids);nan(1,sum(idx_uids))];
                    line(UI.plot_axis1,xdata(:),ydata(:), 'color', [uid_colormap(i,:),0.4],'HitTest','off')
                end
                
            elseif plotStyle == 3 % Electrode groups
                raster.electrodeGroup(raster.times<=wfWin_sec | raster.times>=UI.settings.windowDuration-wfWin_sec)=[];
                unique_electrodeGroups = unique(raster.electrodeGroup);
                electrodeGroup_colormap = UI.colors;
                for i = 1:numel(unique_electrodeGroups)
                    idx_uids = raster.electrodeGroup == unique_electrodeGroups(i);
                    xdata = [waveforms_xdata(:,idx_uids);nan(1,sum(idx_uids))];
                    ydata = [waveforms(:,idx_uids);nan(1,sum(idx_uids))];
                    line(UI.plot_axis1,xdata(:),ydata(:), 'color', [electrodeGroup_colormap(unique_electrodeGroups(i),:),0.4],'HitTest','off')
                end
                
            elseif plotStyle == 2 % Single group
                xdata = [waveforms_xdata;nan(1,size(waveforms,2))];
                ydata = [waveforms;nan(1,size(waveforms,2))];
                line(UI.plot_axis1,xdata(:),ydata(:), 'color', [lineColor,0.4],'HitTest','off')
                
            elseif plotStyle == 5 % Colored by spike waveform width
                
                [~,idx_min] = min(waveforms(round(wfWin_sec*ephys.sr):end,:));
                [~,idx_max] = max(waveforms(round(wfWin_sec*ephys.sr):end,:));
                spike_width = idx_max-idx_min;
                spike_identity = double(spike_width>UI.settings.interneuronMaxWidth*ephys.sr/1000)+1;
                raster.spike_identity = spike_identity;
                unique_electrodeGroups = unique(spike_identity);
                spike_identity_colormap = [0.3 0.3 1; 1 0.3 0.3];
                labels_cell_types = {'Narrow waveform','Wide waveform'};
                addLegend('Spike waveforms')
                for i = 1:numel(unique_electrodeGroups)
                    idx_uids = spike_identity == i;
                    xdata = [waveforms_xdata(:,idx_uids);nan(1,sum(idx_uids))];
                    ydata = [waveforms(:,idx_uids);nan(1,sum(idx_uids))];
                    line(UI.plot_axis1,xdata(:),ydata(:), 'color', [spike_identity_colormap(unique_electrodeGroups(i),:),0.5],'HitTest','off')
                    addLegend(labels_cell_types{unique_electrodeGroups(i)},num2strCommaSeparated(spike_identity_colormap(unique_electrodeGroups(i),:)));
                end

            elseif plotStyle == 4 % Group data from Cell metrics
                raster.UID(raster.times<=wfWin_sec | raster.times>=UI.settings.windowDuration-wfWin_sec)=[];
                putativeCellTypes = unique(data.cell_metrics.(UI.params.groupMetric));
                UI.colors_metrics = eval([UI.settings.spikesColormap,'(',num2str(numel(putativeCellTypes)),')']);
                for i = 1:numel(putativeCellTypes)
                    idx2 = find(ismember(data.cell_metrics.(UI.params.groupMetric),putativeCellTypes{i}));
                    idx3 = ismember(raster.UID,idx2);
                    if any(idx3)
                        xdata = [waveforms_xdata(:,idx3);nan(1,sum(idx3))];
                        ydata = [waveforms(:,idx3);nan(1,sum(idx3))];
                        line(UI.plot_axis1,xdata(:),ydata(:), 'color', [UI.colors_metrics(i,:),0.4],'HitTest','off')
                    end
                end
            end
        end
    end
    
    function raster = plotPopulationRate(raster,lineColor,plotStyle)
        if ~UI.settings.populationRateBelowTrace
            UI.dataRange.populationRate(2) = 0.1;
        end
        populationBins = 0:UI.settings.populationRateWindow:UI.settings.windowDuration;
        if plotStyle == 4 % Group data from Cell metrics
            putativeCellTypes = unique(data.cell_metrics.(UI.params.groupMetric));
            UI.colors_metrics = eval([UI.settings.spikesColormap,'(',num2str(numel(putativeCellTypes)),')']);
            
            for i = 1:numel(putativeCellTypes)
                idx2 = find(ismember(data.cell_metrics.(UI.params.groupMetric),putativeCellTypes{i}));
                idx3 = ismember(raster.UID,idx2);
                
                if any(idx3)
                    populationRate = histcounts(raster.x(idx3),populationBins)/UI.settings.populationRateWindow/2;
                    if UI.settings.populationRateSmoothing == 1
                        populationRate = [populationRate;populationRate];
                        populationRate = populationRate(:);
                        populationBins = [populationBins(1:end-1);populationBins(2:end)];
                        populationBins = populationBins(:);
                    else
                        populationBins = populationBins(1:end-1)+UI.settings.populationRateWindow/2;
                        % populationRate = smooth(populationRate,UI.settings.populationRateSmoothing);
                        populationRate = conv(populationRate,ce_gausswin(UI.settings.populationRateSmoothing)'/sum(ce_gausswin(UI.settings.populationRateSmoothing)),'same');
                    end
                    populationRate = (populationRate/max(populationRate))*diff(UI.dataRange.populationRate)+UI.dataRange.populationRate(1)+0.001;
                    line(populationBins, populationRate,'Marker','none','LineStyle','-','color',UI.colors_metrics(i,:), 'HitTest','off','linewidth',1.5);
                end
            end
        elseif plotStyle == 3 % Electrode groups
            unique_electrodeGroups = unique(raster.electrodeGroup);
            electrodeGroup_colormap = UI.colors;
            for i = 1:numel(unique_electrodeGroups)
                idx3 = raster.electrodeGroup==unique_electrodeGroups(i);
                if any(idx3)
                    populationRate = histcounts(raster.x(idx3),populationBins)/UI.settings.populationRateWindow/2;
                    if UI.settings.populationRateSmoothing == 1
                        populationRate = [populationRate;populationRate];
                        populationRate = populationRate(:);
                        populationBins = [populationBins(1:end-1);populationBins(2:end)];
                        populationBins = populationBins(:);
                    else
                        populationBins = populationBins(1:end-1)+UI.settings.populationRateWindow/2;
                        populationRate = conv(populationRate,ce_gausswin(UI.settings.populationRateSmoothing)'/sum(ce_gausswin(UI.settings.populationRateSmoothing)),'same');
                    end
                    populationRate = (populationRate/max(populationRate))*diff(UI.dataRange.populationRate)+UI.dataRange.populationRate(1)+0.001;
                    line(populationBins, populationRate,'Marker','none','LineStyle','-','color',electrodeGroup_colormap(unique_electrodeGroups(i),:), 'HitTest','off','linewidth',1.5);
                end
            end
            
        elseif plotStyle == 5 % Colored by spike waveform width
            spike_identity = raster.spike_identity;
            unique_electrodeGroups = unique(spike_identity);
            spike_identity_colormap = [0.3 0.3 1; 1 0.3 0.3];
            labels_cell_types = {'Narrow waveform','Wide waveform'};
%             addLegend('Population rate: waveform width')
            for i = 1:numel(unique_electrodeGroups)
                idx_uids = spike_identity == i;
                populationRate = histcounts(raster.x(idx_uids),populationBins)/UI.settings.populationRateWindow/2;
                if UI.settings.populationRateSmoothing == 1
                    populationRate = [populationRate;populationRate];
                    populationRate = populationRate(:);
                    populationBins = [populationBins(1:end-1);populationBins(2:end)];
                    populationBins = populationBins(:);
                else
                    populationBins = populationBins(1:end-1)+UI.settings.populationRateWindow/2;
                    populationRate = conv(populationRate,ce_gausswin(UI.settings.populationRateSmoothing)'/sum(ce_gausswin(UI.settings.populationRateSmoothing)),'same');
                end
                populationRate = (populationRate/max(populationRate))*diff(UI.dataRange.populationRate)+UI.dataRange.populationRate(1)+0.001;
                line(populationBins, populationRate,'Marker','none','LineStyle','-','color',[spike_identity_colormap(unique_electrodeGroups(i),:),0.5], 'HitTest','off','linewidth',1.5);
%                 addLegend(labels_cell_types{unique_electrodeGroups(i)},num2strCommaSeparated(spike_identity_colormap(unique_electrodeGroups(i),:)));
            end
            
        else % 1: UID, 2: Single group
            populationRate = histcounts(raster.x,populationBins)/UI.settings.populationRateWindow;
            if UI.settings.populationRateSmoothing == 1
                populationRate = [populationRate;populationRate];
                populationRate = populationRate(:);
                populationBins = [populationBins(1:end-1);populationBins(2:end)];
                populationBins = populationBins(:);
            else
                populationBins = populationBins(1:end-1)+UI.settings.populationRateWindow/2;
                populationRate = conv(populationRate,gausswin(UI.settings.populationRateSmoothing)'/sum(gausswin(UI.settings.populationRateSmoothing)),'same');
            end
            populationRate = (populationRate/max(populationRate))*diff(UI.dataRange.populationRate)+UI.dataRange.populationRate(1)+0.001;
            line(populationBins, populationRate,'Marker','none','LineStyle','-','color',lineColor, 'HitTest','off','linewidth',1.5);
        end
        
    end
    
    function plotSpikesPCAspace(raster,lineColor,drawBackground)
        
        wfWin_sec = 0.0008; % Default: 2*0.8ms window size
        wfWin = round(wfWin_sec * ephys.sr); % Windows size in sample
            
        raster.channel(raster.times<=wfWin_sec | raster.times>=UI.settings.windowDuration-wfWin_sec)=[];
        raster.idx(raster.times<=wfWin_sec | raster.times>=UI.settings.windowDuration-wfWin_sec)=[];        
        raster1 = raster.idx(ismember(raster.channel,UI.channels{UI.settings.PCAspace_electrodeGroup}));
        
        % Pulling waveforms
        if ~isempty(raster1) && numel(raster1)>1
            nChannels = numel(UI.channels{UI.settings.PCAspace_electrodeGroup});
            startIndicies2 = (raster1 - wfWin)*nChannels+1;
            stopIndicies2 = (raster1 + wfWin)*nChannels;
            X2 = cumsum(accumarray(cumsum([1;stopIndicies2(:)-startIndicies2(:)+1]),[startIndicies2(:);0]-[0;stopIndicies2(:)]-1)+1);
            if isfield(ephys,'filt')
                ephys_data = ephys.filt(:,UI.channels{UI.settings.PCAspace_electrodeGroup})';
            else
                ephys_data = ephys.traces(:,UI.channels{UI.settings.PCAspace_electrodeGroup})';
            end
            wf = reshape(ephys_data(X2(1:end-1)),nChannels,(wfWin*2),[]);
            wf2 = reshape(permute(wf,[2,1,3]),nChannels*(wfWin*2),[]);
            
            abc = pca(wf2,'NumComponents',2);

            % Drawing background
            if drawBackground
                p1 = patch(UI.plot_axis1,[(1-UI.settings.insetRelativeWidth)*UI.settings.windowDuration,UI.settings.windowDuration,UI.settings.windowDuration,(1-UI.settings.insetRelativeWidth)*UI.settings.windowDuration]-0.005,[(1-UI.settings.insetRelativeHeight) (1-UI.settings.insetRelativeHeight) 1 1]-0.015,'k','HitTest','off','EdgeColor',[0.5 0.5 0.5]);
                alpha(p1,0.6);
            end
            
            % Drawing PCA values
            xlim1 = [min(abc(:,1)),max(abc(:,1))];
            ylim1 = [min(abc(:,2)),max(abc(:,2))];
            line(UI.plot_axis1,(abc(:,1)-xlim1(1))/diff(xlim1)*UI.settings.insetRelativeWidth*UI.settings.windowDuration+(1-UI.settings.insetRelativeWidth)*UI.settings.windowDuration-0.005,(abc(:,2)-ylim1(1))/diff(ylim1)*UI.settings.insetRelativeHeight+(0.985-UI.settings.insetRelativeHeight), 'HitTest','off','Color', lineColor,'Marker','o','LineStyle','none','linewidth',2,'MarkerFaceColor',lineColor,'MarkerEdgeColor',lineColor)
        end
    end

    function plotSpikesAmplitudeDistribution(raster,lineColor,drawBackground)

        spike_amplitudes = [];

        wfWin_sec = UI.settings.spikeWaveformWidth;
        wfWin = round(wfWin_sec * ephys.sr); % Windows size in sample
        
        % Removing spikes around the borders
        indexes = raster.times<=wfWin_sec | raster.times>=UI.settings.windowDuration-wfWin_sec;
        raster.channel(indexes)=[];
        raster.times(indexes)=[];

        channels_with_spikes = unique(raster.channel);
        
        for j = 1:numel(channels_with_spikes)
            i = channels_with_spikes(j);
            timestamps = round(raster.times(raster.channel==i) * ephys.sr);
            
            if ~isempty(timestamps)
                startIndicies2 = (timestamps - wfWin)+1;
                stopIndicies2 = (timestamps + wfWin);
                X2 = cumsum(accumarray(cumsum([1;stopIndicies2(:)-startIndicies2(:)+1]),[startIndicies2(:);0]-[0;stopIndicies2(:)]-1)+1);
                if ~UI.settings.filterTraces
                    ephys_data = ephys.filt(:,i)';
                else                   
                    ephys_data = ephys.traces(:,i)';
                end
                
                wf = reshape(double(ephys_data(X2(1:end-1))),1,(wfWin*2),[]);
                wf2 = reshape(permute(wf,[2,1,3]),(wfWin*2),[]);

                spike_amplitudes = [spike_amplitudes, range(wf2)];
            end
        end
        
        % Pulling waveforms
        if ~isempty(spike_amplitudes)

            [histcounts_spike_amplitudes,bins__spike_amplitudes] = histcounts(spike_amplitudes,linspace(min(spike_amplitudes),ceil(max(spike_amplitudes)/10)*10,20));
            bins__spike_amplitudes = bins__spike_amplitudes(1:end-1)-diff(bins__spike_amplitudes(1:2))/2;

            % Drawing background
            if drawBackground
                p1 = patch(UI.plot_axis1,[(1-UI.settings.insetRelativeWidth)*UI.settings.windowDuration,UI.settings.windowDuration,UI.settings.windowDuration,(1-UI.settings.insetRelativeWidth)*UI.settings.windowDuration]-0.005,[(1-UI.settings.insetRelativeHeight) (1-UI.settings.insetRelativeHeight) 1 1]-0.015,'k','HitTest','off','EdgeColor',[0.5 0.5 0.5]);
                alpha(p1,0.6);
            end
            
            % Drawing histogram of spike amplitudes
            xlim1 = [0,max(bins__spike_amplitudes)];
            ylim1 = [0,max(histcounts_spike_amplitudes)];
            line(UI.plot_axis1,(bins__spike_amplitudes-xlim1(1))/diff(xlim1)*UI.settings.insetRelativeWidth*UI.settings.windowDuration+(1-UI.settings.insetRelativeWidth)*UI.settings.windowDuration-0.005,(histcounts_spike_amplitudes-ylim1(1))/diff(ylim1)*UI.settings.insetRelativeHeight+(0.985-UI.settings.insetRelativeHeight), 'HitTest','off','Color', lineColor,'Marker','o','LineStyle','-','linewidth',2,'MarkerFaceColor',lineColor,'MarkerEdgeColor',lineColor)
            
            text(UI.plot_axis1,(1-UI.settings.insetRelativeWidth)*UI.settings.windowDuration-0.005,0.984,[' ', num2str(xlim1(1),3),char(181),'V'],'FontWeight', 'Bold','VerticalAlignment', 'top','HorizontalAlignment','left','color',UI.settings.primaryColor,'FontSize',12)
            text(UI.plot_axis1,1-0.005,0.984,[' ', num2str(xlim1(2),3),char(181),'V'],'FontWeight', 'Bold','VerticalAlignment', 'top','HorizontalAlignment','right','color',UI.settings.primaryColor,'FontSize',12)
        end
    end

    function plotSpikesCountAcrossChannels(raster,lineColor,drawBackground)

        raster.count_across_channels = zeros(1,length(UI.channelOrder));
        k_channels = 0;

        for i = 1:length(UI.channelOrder)
            raster.count_across_channels(UI.channelOrder(i)) = sum(raster.channel==UI.channelOrder(i));
        end

        % Drawing background
        if drawBackground
            p1 = patch(UI.plot_axis1,[(1-UI.settings.insetRelativeWidth)*UI.settings.windowDuration,UI.settings.windowDuration,UI.settings.windowDuration,(1-UI.settings.insetRelativeWidth)*UI.settings.windowDuration]-0.005,[(1-UI.settings.insetRelativeHeight) (1-UI.settings.insetRelativeHeight) 1 1]-0.015,'k','HitTest','off','EdgeColor',[0.5 0.5 0.5]);
            alpha(p1,0.6);
        end
        
        xlim1 = [0,numel([UI.channelOrder])+1];
        ylim1 = [0,max(raster.count_across_channels)];

        % Drawing noise curves
        for iShanks = UI.settings.electrodeGroupsToPlot
            channels = UI.channels{iShanks};
            [~,ia,~] = intersect(UI.channelOrder,channels,'stable');
            channels = UI.channelOrder(ia);
            markerColor = UI.colors(iShanks,:);
            x_data = (1:numel(channels))+k_channels;
            y_data = raster.count_across_channels(channels);
            line(UI.plot_axis1,(x_data-xlim1(1))/diff(xlim1)*UI.settings.insetRelativeWidth*UI.settings.windowDuration+(1-UI.settings.insetRelativeWidth)*UI.settings.windowDuration-0.005,(y_data-ylim1(1))/diff(ylim1)*UI.settings.insetRelativeHeight+(0.985-UI.settings.insetRelativeHeight), 'HitTest','off','Color', markerColor,'Marker','o','LineStyle','-','linewidth',2,'MarkerFaceColor',markerColor,'MarkerEdgeColor',markerColor)
            k_channels = k_channels + numel(channels);
        end
        text(UI.plot_axis1,(1-UI.settings.insetRelativeWidth)*UI.settings.windowDuration-0.005,0.984,[' Max spikes: ', num2str(ylim1(2),3),'. Total: ' num2str(sum(raster.count_across_channels))],'FontWeight', 'Bold','VerticalAlignment', 'top','HorizontalAlignment','left','color',UI.settings.primaryColor,'FontSize',12)
    end
    
    function highlightUnits(units2plot,colorIn)
        % Highlight ephys channel(s)
        if ~isempty(colorIn)
            colorLine = colorIn;
        else
            UI.iLine = mod(UI.iLine,7)+1;
            colorLine = UI.colorLine(UI.iLine,:);
        end
        idx = ismember(spikes_raster.UID,units2plot);
        uid = spikes_raster.UID(idx);
        raster_x = spikes_raster.x(idx);
        raster_y = spikes_raster.y(idx);
        
        if numel(units2plot) == 1
            line(raster_x, raster_y,'Marker',UI.settings.rasterMarker,'LineStyle','none','color',colorLine, 'HitTest','off','linewidth',3);
        else
            uid_colormap = eval([UI.settings.spikesColormap,'(',num2str(numel(units2plot)),')']);
            for i = 1:numel(units2plot)
                idx_uids = uid == units2plot(i);
                line(raster_x(idx_uids), raster_y(idx_uids),'Marker',UI.settings.rasterMarker,'LineStyle','none','color',uid_colormap(i,:), 'HitTest','off','linewidth',3);
            end
        end        
    end

    function plotKilosortData(t1,t2,colorIn)
        % Plots spikes
        idx = data.spikes_kilosort.spindices(:,1) > t1 & data.spikes_kilosort.spindices(:,1) < t2 &  ismember(data.spikes_kilosort.spindices(:,3),UI.channelOrder);
        if any(idx)
            raster = [];
            raster.x = data.spikes_kilosort.spindices(idx,1)-t1;
            idx2 = round(raster.x*size(ephys.traces,1)/UI.settings.windowDuration);
            if UI.settings.kilosortBelowTrace
                sortIdx = 1:data.spikes_kilosort.numcells;
                raster.y = (diff(UI.dataRange.kilosort))*(sortIdx(data.spikes_kilosort.spindices(idx,2))/(data.spikes_kilosort.numcells))+UI.dataRange.kilosort(1);
                text(1/400,UI.dataRange.kilosort(2),'Kilosort','color',colorIn,'FontWeight', 'Bold','BackgroundColor',UI.settings.textBackground, 'HitTest','off','VerticalAlignment', 'top')
            else
                idx3 = sub2ind(size(ephys.traces),idx2,data.spikes_kilosort.spindices(idx,3));
                raster.y = ephys.traces(idx3)-UI.channelScaling(idx3);
            end
            line(raster.x, raster.y,'Marker','o','LineStyle','none','color',colorIn, 'HitTest','off','linewidth',UI.settings.spikeRasterLinewidth);
        end
    end
    
    function plotSpykingcircusData(t1,t2,colorIn)
        % Plots spikes
        units2plot = find(ismember(data.spikes_spykingcircus.maxWaveformCh1,[UI.channels{UI.settings.electrodeGroupsToPlot}]));
        idx = data.spikes_spykingcircus.spindices(:,1) > t1 & data.spikes_spykingcircus.spindices(:,1) < t2;
        if any(idx)
            raster = [];
            raster.x = data.spikes_spykingcircus.spindices(idx,1)-t1;
            idx2 = round(raster.x*size(ephys.traces,1)/UI.settings.windowDuration);
            if UI.settings.spykingcircusBelowTrace
                sortIdx = 1:data.spikes_spykingcircus.numcells;
                raster.y = (diff(UI.dataRange.spykingcircus))*(sortIdx(data.spikes_spykingcircus.spindices(idx,2))/(data.spikes_spykingcircus.numcells))+UI.dataRange.spykingcircus(1);
                text(1/400,UI.dataRange.spykingcircus(2),'SpyKING Circus','color',colorIn,'FontWeight', 'Bold','BackgroundColor',UI.settings.textBackground, 'HitTest','off','VerticalAlignment', 'top')
            else
                idx3 = sub2ind(size(ephys.traces),idx2,data.spikes_spykingcircus.maxWaveformCh1(data.spikes_spykingcircus.spindices(idx,2))');
                raster.y = ephys.traces(idx3)-UI.channelScaling(idx3);
            end
            line(raster.x, raster.y,'Marker','o','LineStyle','none','color',colorIn, 'HitTest','off','linewidth',UI.settings.spikeRasterLinewidth);
        end
    end
    
    function plotKlustaData(t1,t2,colorIn)
        % Plots spikes
        units2plot = find(ismember(data.spikes_klusta.maxWaveformCh1,[UI.channels{UI.settings.electrodeGroupsToPlot}]));
        idx = data.spikes_klusta.spindices(:,1) > t1 & data.spikes_klusta.spindices(:,1) < t2;
        if any(idx)
            raster = [];
            raster.x = data.spikes_klusta.spindices(idx,1)-t1;
            idx2 = round(raster.x*size(ephys.traces,1)/UI.settings.windowDuration);
            if UI.settings.klustaBelowTrace
                sortIdx = 1:data.spikes_klusta.numcells;
                raster.y = (diff(UI.dataRange.klusta))*(sortIdx(data.spikes_klusta.spindices(idx,2))/(data.spikes_klusta.numcells))+UI.dataRange.klusta(1);
                text(1/400,UI.dataRange.klusta(2),'SpyKING Circus','color',colorIn,'FontWeight', 'Bold','BackgroundColor',UI.settings.textBackground, 'HitTest','off','VerticalAlignment', 'top')
            else
                idx3 = sub2ind(size(ephys.traces),idx2,data.spikes_klusta.maxWaveformCh1(data.spikes_klusta.spindices(idx,2))');
                raster.y = ephys.traces(idx3)-UI.channelScaling(idx3);
            end
            line(raster.x, raster.y,'Marker','o','LineStyle','none','color',colorIn, 'HitTest','off','linewidth',UI.settings.spikeRasterLinewidth);
        end
    end

    function plotEventData(eventName,t1,t2,colorIn1)
        if strcmp(UI.settings.eventData,eventName)
        	colorIn1 = UI.settings.primaryColor;
        end
        
        % Plot events
        ydata = UI.dataRange.events';
        events_idx = find(strcmp(eventName,UI.data.detectecFiles.events));
        
        % Setting y-limits of event rasters        
        if UI.settings.processing_steps && ~any(UI.settings.showEventsBelowTrace & UI.settings.showEvents)
            ydata2 = [UI.dataRange.processing(2);1];
        elseif any(UI.settings.showEventsBelowTrace & UI.settings.showEvents) && ~UI.settings.showEventsBelowTrace(events_idx)
            ydata2 = [ydata(2);1];
        elseif ~UI.settings.showEventsBelowTrace(events_idx)
            ydata2 = [0;1];
        else
            nBelow = sum(UI.settings.showEvents & UI.settings.showEventsBelowTrace);
            y_height = diff(ydata)/nBelow;
            events_idx_below = find(strcmp(eventName,UI.data.detectecFiles.events(UI.settings.showEvents & UI.settings.showEventsBelowTrace)))-1;
            ydata2 = [ydata(1);ydata(1)+y_height]+y_height*events_idx_below;
        end
        
        % Setting linewidth
        if UI.settings.showEventsBelowTrace(events_idx)
            linewidth = 1.5;
        else
            linewidth = 0.8;
        end
        
        % Detmermining events within
        idx = find(data.events.(eventName).time >= t1 & data.events.(eventName).time <= t2);
        
        % Plotting flagged events in a different color
        if isfield(data.events.(eventName),'flagged')
            idx2 = ismember(idx,data.events.(eventName).flagged);
            if any(idx2)
                plotEventLines(data.events.(eventName).time(idx(idx2))-t1,'m',linewidth)
                addLegend('Flagged events',[1, 0, 1]);
            end
            idx(idx2) = [];
        end
        
        % Plotting events
        if any(idx)
            plotEventLines(data.events.(eventName).time(idx)-t1,colorIn1,linewidth)
        end
        
        % Plotting added events
        if isfield(data.events.(eventName),'added') && ~isempty(isfield(data.events.(eventName),'added'))
            idx3 = find(data.events.(eventName).added >= t1 & data.events.(eventName).added <= t2);
            if any(idx3)
                plotEventLines(data.events.(eventName).added(idx3)-t1,'c',linewidth)
                addLegend('Added events',[0, 1, 1]);
            end
        end
        
        % Plotting manually created event intervals
        if UI.settings.showEventsIntervals && isfield(data.events.(eventName),'added_intervals')
            idx3 = find(data.events.(eventName).added_intervals(:,2) >= t1 & data.events.(eventName).added_intervals(:,1) <= t2);
            if any(idx3)
                statesData = data.events.(eventName).added_intervals(idx3,:)-t1;
                p1 = patch(double([statesData,flip(statesData,2)])',[ydata2(1);ydata2(1);ydata2(2);ydata2(2)]*ones(1,size(statesData,1)),'b','EdgeColor','b','HitTest','off');
                alpha(p1,0.2);
                addLegend('Added event intervals',[0, 0, 1]);
            end
        end
        
        spec_text = {};
        if strcmp(UI.settings.eventData,eventName)
            % Plotting processing steps
            if UI.settings.processing_steps && isfield(data.events.(eventName),'processing_steps')
                fields2plot = fieldnames(data.events.(eventName).processing_steps);
                UI.colors_processing_steps = hsv(numel(fields2plot));
                ydata1 = UI.dataRange.processing(1)+[0;diff(UI.dataRange.processing)/10];
%                 addLegend(['Processing steps: ' eventName])
                for i = 1:numel(fields2plot)
                    idx5 = find(data.events.(eventName).processing_steps.(fields2plot{i}) >= t1 & data.events.(eventName).processing_steps.(fields2plot{i}) <= t2);
                    if any(idx5)
                        line([1;1]*data.events.(eventName).processing_steps.(fields2plot{i})(idx5)'-t1,0.00435*i+ydata1*ones(1,numel(idx5)),'Marker','none','LineStyle','-','color',UI.colors_processing_steps(i,:), 'HitTest','off','linewidth',2);
                        addLegend(strrep(fields2plot{i}, '_', ' '),UI.colors_processing_steps(i,:)*0.8);
                    else
                        addLegend(fields2plot{i},[0.5, 0.5, 0.5]);
                    end
                end
                
                % Specs
                idx_center = find(data.events.(eventName).time == t1+UI.settings.windowDuration/2);
                if ~isempty(idx_center)
                    if isfield(data.events.(eventName),'peakNormedPower')
                        spec_text = [spec_text;['Power: ', num2str(data.events.(eventName).peakNormedPower(idx_center))]];
                    end                    
                end
            end
            
            % Plotting event intervals
            if UI.settings.showEventsIntervals
                statesData = data.events.(eventName).timestamps(idx,:)-t1;
                if ~isempty(statesData)
                    p1 = patch(double([statesData,flip(statesData,2)])',[ydata2(1);ydata2(1);ydata2(2);ydata2(2)]*ones(1,size(statesData,1)),'g','EdgeColor','g','HitTest','off');
                    alpha(p1,0.1);
                    % Duration text
                    idx_center = find(data.events.(eventName).time == t1+UI.settings.windowDuration/2);
                    if ~isempty(idx_center)
                        if isfield(data.events.(eventName),'timestamps')
                            spec_text = [spec_text;['Duration: ', num2str(diff(data.events.(eventName).timestamps(idx_center,:))),' sec']];
                        end
                    end
                end
            end
            
            if ~isempty(spec_text)
                text(1/400+UI.settings.windowDuration/2,1,spec_text,'color',[1 1 1],'FontWeight', 'Bold','BackgroundColor',UI.settings.textBackground, 'HitTest','off','Units','normalized','verticalalignment','top')
            end            
            
            % Highlighting detection channel
            if isfield(data.events.(eventName),'detectorParams')
                detector_channel = data.events.(eventName).detectorParams.channel+1;
            elseif isfield(data.events.(eventName),'detectorinfo') & isfield(data.events.(eventName).detectorinfo,'detectionchannel')
                detector_channel = data.events.(eventName).detectorinfo.detectionchannel+1;
            else
                detector_channel = [];
            end
            if ~isempty(detector_channel) && ismember(detector_channel,UI.channelOrder)
                highlightTraces(detector_channel,UI.settings.primaryColor)
            end
            
        end
        
        
        function plotEventLines(timestamps,clr,linewidth)
            timestamps = timestamps(:)';
            if UI.settings.plotTracesInColumns &&  ~UI.settings.showEventsBelowTrace(events_idx)
                timestamps1 = timestamps'/UI.settings.columns+UI.settings.channels_relative_offset(UI.channelOrder);
                xdata3 = ones(3,1)*timestamps1(:)';
                
                ydata3 = zeros(length(timestamps),1)-UI.channelOffset(UI.channelOrder);
                ydata3 = [-UI.settings.columns_height/2;UI.settings.columns_height/2;nan]+ydata3(:)';

                line(xdata3(:),ydata3(:),'Marker','none','LineStyle','-','color',clr, 'HitTest','off','linewidth',linewidth);
            else
                line([1;1]*timestamps,ydata2*ones(1,numel(timestamps)),'Marker','none','LineStyle','-','color',clr, 'HitTest','off','linewidth',linewidth);
                
            end            
        end
    end

    function plotTimeseriesData(timeserieName,t1,t2,colorIn,linewidth)
        % Plot time series
        idx = data.timeseries.(timeserieName).timestamps>=t1 & data.timeseries.(timeserieName).timestamps<=t2;
        if any(idx)
            switch UI.settings.timeseries.(timeserieName).range
                case 'Full trace'
                    lowerBoundary = UI.settings.timeseries.(timeserieName).lowerBoundary(UI.settings.timeseries.(timeserieName).channels);
                    upperBoundary = UI.settings.timeseries.(timeserieName).upperBoundary(UI.settings.timeseries.(timeserieName).channels);
                case 'Window'
                    lowerBoundary = min(data.timeseries.(timeserieName).data(idx,UI.settings.timeseries.(timeserieName).channels));
                    upperBoundary = max(data.timeseries.(timeserieName).data(idx,UI.settings.timeseries.(timeserieName).channels));
                case 'Custom'
                    lowerBoundary = UI.settings.timeseries.(timeserieName).custom(1);
                    upperBoundary = UI.settings.timeseries.(timeserieName).custom(2);
            end
            if length(UI.settings.timeseries.(timeserieName).channels)>1
                colorIn_map = (colorIn' * linspace(0.7,1,length(UI.settings.timeseries.(timeserieName).channels)))';
                for i_channels = 1:length(UI.settings.timeseries.(timeserieName).channels)
                    lowerBoundary1 = lowerBoundary(i_channels);
                    upperBoundary1 = upperBoundary(i_channels);
                    line(data.timeseries.(timeserieName).timestamps(idx)-t1,(data.timeseries.(timeserieName).data(idx,UI.settings.timeseries.(timeserieName).channels(i_channels)) - lowerBoundary1)./(upperBoundary1-lowerBoundary1),'color',colorIn_map(i_channels,:), 'HitTest','off','linewidth',linewidth,'LineStyle','none','Marker','*');
                    if isfield(data.timeseries.(timeserieName),'channelNames') && length(data.timeseries.(timeserieName).channelNames)>=i_channels
                        addLegend([timeserieName,': ', data.timeseries.(timeserieName).channelNames{UI.settings.timeseries.(timeserieName).channels(i_channels)}],colorIn_map(i_channels,:));
                    end
                end
                if ~isfield(data.timeseries.(timeserieName),'channelNames')
                    addLegend(timeserieName,colorIn);
                end
            else
                line(data.timeseries.(timeserieName).timestamps(idx)-t1,(data.timeseries.(timeserieName).data(idx,UI.settings.timeseries.(timeserieName).channels) - lowerBoundary)./(upperBoundary-lowerBoundary),'color',colorIn, 'HitTest','off','linewidth',linewidth,'LineStyle','none','Marker','*');
                addLegend(timeserieName,colorIn);
            end
            
        end
    end

    function plotTrials(t1,t2)
        % Plot trials
        intervals = [data.behavior.(UI.settings.behaviorData).trials.(UI.settings.trialsData).start,data.behavior.(UI.settings.behaviorData).trials.(UI.settings.trialsData).end];
        idx = (intervals(:,1)<t2 & intervals(:,2)>t1);
        patch_range = UI.dataRange.trials;
        if any(idx)
            intervals = intervals(idx,:)-t1;
            intervals(intervals<0) = 0; intervals(intervals>t2-t1) = t2-t1;
            p1 = patch(double([intervals,flip(intervals,2)])',[patch_range(1);patch_range(1);patch_range(2);patch_range(2)]*ones(1,size(intervals,1)),'g','EdgeColor','g','HitTest','off');
            alpha(p1,0.3);
            text(intervals(:,1),patch_range(2)*ones(1,size(intervals,1)),strcat({' Trial '}, num2str(find(idx))),'FontWeight', 'Bold','Color',UI.settings.primaryColor,'margin',0.1,'VerticalAlignment', 'top')
        end
    end
    
    function plotSpectrogram
        if ismember(UI.settings.spectrogram.channel,UI.channelOrder)
            spectrogram_range = UI.dataRange.spectrogram;
            window = UI.settings.spectrogram.window;
            freq_range = UI.settings.spectrogram.freq_range;
            y_ticks = UI.settings.spectrogram.y_ticks;
            
            [s, ~, t] = spectrogram(ephys.traces(:,UI.settings.spectrogram.channel)*5, round(ephys.sr*UI.settings.spectrogram.window) ,round(ephys.sr*UI.settings.spectrogram.window*0.95), UI.settings.spectrogram.freq_range, ephys.sr);
            multiplier = [0:size(s,1)-1]/(size(s,1)-1)*diff(spectrogram_range)+spectrogram_range(1);
            
            scaling = 200;
            axis_labels = interp1(freq_range,multiplier,y_ticks);
            image(UI.plot_axis1,'XData',t,'YData',multiplier,'CData',scaling*log10(abs(s)), 'HitTest','off');
            text(UI.plot_axis1,t(1)*ones(size(y_ticks)),axis_labels,num2str(y_ticks(:)),'FontWeight', 'Bold','color',UI.settings.primaryColor,'margin',1, 'HitTest','off','HorizontalAlignment','left','BackgroundColor',[0 0 0 0.5]);
            if ismember(UI.settings.spectrogram.channel,UI.channelOrder)
                highlightTraces(UI.settings.spectrogram.channel,'m')
            end
        end
    end
    
    function plotInstantaneousMetrics        
        if int_gt_0(UI.settings.instantaneousMetrics.lowerBand,ephys.sr) && int_gt_0(UI.settings.instantaneousMetrics.higherBand,ephys.sr)
            return
        elseif int_gt_0(UI.settings.instantaneousMetrics.lowerBand,ephys.sr) && ~int_gt_0(UI.settings.instantaneousMetrics.higherBand,ephys.sr)
            [UI.settings.instantaneousMetrics.b1, UI.settings.instantaneousMetrics.a1] = butter(3, UI.settings.instantaneousMetrics.higherBand/(ephys.sr/2), 'low');
        elseif int_gt_0(UI.settings.instantaneousMetrics.higherBand,ephys.sr) && ~int_gt_0(UI.settings.instantaneousMetrics.lowerBand,ephys.sr)
            [UI.settings.instantaneousMetrics.b1, UI.settings.instantaneousMetrics.a1] = butter(3, UI.settings.instantaneousMetrics.lowerBand/(ephys.sr/2), 'high');
        else
            [UI.settings.instantaneousMetrics.b1, UI.settings.instantaneousMetrics.a1] = butter(3, [UI.settings.instantaneousMetrics.lowerBand,UI.settings.instantaneousMetrics.higherBand]/(ephys.sr/2), 'bandpass');
        end
        filtered = filtfilt(UI.settings.instantaneousMetrics.b1, UI.settings.instantaneousMetrics.a1, ephys.raw(:,UI.settings.instantaneousMetrics.channel))';

        timestamps = [1:length(filtered)]/ephys.sr;
        
        % Compute instantaneous phase and amplitude
        h = hilbert(filtered);
        phase = angle(h);
        amplitude = abs(h);
        unwrapped = unwrap(phase);
        
        % Compute instantaneous frequency
%         frequency = diff(medfilt1(unwrapped,12*16))./diff(timestamps)/(2*pi);
        frequency = diff(unwrapped)./diff(timestamps)/(2*pi);
        
        dataRange = diff(UI.dataRange.instantaneousMetrics)/(UI.settings.instantaneousMetrics.showSignal+UI.settings.instantaneousMetrics.showPower+UI.settings.instantaneousMetrics.showPhase+0.001);
        
        k = (UI.settings.instantaneousMetrics.showSignal+UI.settings.instantaneousMetrics.showPower+UI.settings.instantaneousMetrics.showPhase);
        addLegend('Instantaneous metrics');
        k = k-1;
        filtered = ((filtered-min(filtered))/(max(filtered)-min(filtered)))*dataRange+UI.dataRange.instantaneousMetrics(1)+dataRange*k+0.001;
        if UI.settings.instantaneousMetrics.showSignal
            line(timestamps, filtered,'Marker','none','LineStyle','-','color','m', 'HitTest','off','linewidth',1);
            addLegend('Filtered trace',[1 0 1]);
            k = k-1;
        end
        
%         if UI.settings.instantaneousMetrics.showFrequency
%             frequency = (frequency/max(frequency))*dataRange+UI.dataRange.instantaneousMetrics(1)+dataRange*k+0.001;
%             line(timestamps(1:end-1), frequency,'Marker','none','LineStyle','-','color','g', 'HitTest','off','linewidth',1);
%             addLegend('Frequency',[0 1 0]);
%             k = k-1;
%         end
        if UI.settings.instantaneousMetrics.showPower
            amplitude = (amplitude/max(amplitude))*dataRange+UI.dataRange.instantaneousMetrics(1)+dataRange*k+0.001;
            line(timestamps, amplitude,'Marker','none','LineStyle','-','color','r', 'HitTest','off','linewidth',1);
            addLegend('Amplitude',[1 0 0]);
            k = k-1;
        end
        
        if UI.settings.instantaneousMetrics.showPhase
            phase = ((phase+pi)/(2*pi))*dataRange+UI.dataRange.instantaneousMetrics(1)+dataRange*k+0.001;
            line(timestamps, phase,'Marker','.','LineStyle','none','color','b', 'HitTest','off','linewidth',1);
            addLegend('Phase',[0 0 1]);
        end
        
        if ismember(UI.settings.instantaneousMetrics.channel,UI.channelOrder)
            highlightTraces(UI.settings.instantaneousMetrics.channel,'m')
        end
    end
    
    function plotRMSnoiseInset
        if UI.fid.ephys == -1
            return 
        end
        
        % Shows RMS noise in a small inset plot in the upper right corner
        if UI.settings.plotRMSnoise_apply_filter == 1
            rms1 = rms(ephys.raw/(UI.settings.scalingFactor/1000000));
        elseif UI.settings.plotRMSnoise_apply_filter == 2
            rms1 = rms(ephys.traces/(UI.settings.scalingFactor/1000000));
        else
            if int_gt_0(UI.settings.plotRMSnoise_lowerBand,ephys.sr) && int_gt_0(UI.settings.plotRMSnoise_higherBand,ephys.sr)
                UI.settings.plotRMSnoise_apply_filter = false;
                UI.settings.plotRMSnoise_apply_filter = 1;
                UI.panel.RMSnoiseInset.filter.Value = 1;
                return
            elseif int_gt_0(UI.settings.plotRMSnoise_lowerBand,ephys.sr) && ~int_gt_0(UI.settings.plotRMSnoise_higherBand,ephys.sr)
                [UI.settings.RMSnoise_filter.b1, UI.settings.RMSnoise_filter.a1] = butter(3, UI.settings.plotRMSnoise_higherBand/(ephys.sr/2), 'low');
            elseif int_gt_0(UI.settings.plotRMSnoise_higherBand,ephys.sr) && ~int_gt_0(UI.settings.plotRMSnoise_lowerBand,ephys.sr)
                [UI.settings.RMSnoise_filter.b1, UI.settings.RMSnoise_filter.a1] = butter(3, UI.settings.plotRMSnoise_lowerBand/(ephys.sr/2), 'high');
            else
                [UI.settings.RMSnoise_filter.b1, UI.settings.RMSnoise_filter.a1] = butter(3, [UI.settings.plotRMSnoise_lowerBand,UI.settings.plotRMSnoise_higherBand]/(ephys.sr/2), 'bandpass');
            end
            rms1(UI.channelOrder) = rms(filtfilt(UI.settings.RMSnoise_filter.b1, UI.settings.RMSnoise_filter.a1, ephys.raw(:,UI.channelOrder)));
        end
        k_channels = 0;
        xlim1 = [0,numel([UI.channelOrder])+1];
        ylim1 = [min(rms1(UI.channelOrder)),max(rms1(UI.channelOrder))];
        
        % Drawing background
        p1 = patch(UI.plot_axis1,[(1-UI.settings.insetRelativeWidth)*UI.settings.windowDuration,UI.settings.windowDuration,UI.settings.windowDuration,(1-UI.settings.insetRelativeWidth)*UI.settings.windowDuration]-0.005,[(1-UI.settings.insetRelativeHeight) (1-UI.settings.insetRelativeHeight) 1 1]-0.015,'k','HitTest','off','EdgeColor',[0.5 0.5 0.5]);
        alpha(p1,0.6);
        
        % Drawing noise curves
        for iShanks = UI.settings.electrodeGroupsToPlot
            channels = UI.channels{iShanks};
            [~,ia,~] = intersect(UI.channelOrder,channels,'stable');
            channels = UI.channelOrder(ia);
            markerColor = UI.colors(iShanks,:);
            x_data = (1:numel(channels))+k_channels;
            y_data = rms1(channels);
            line(UI.plot_axis1,(x_data-xlim1(1))/diff(xlim1)*UI.settings.insetRelativeWidth*UI.settings.windowDuration+(1-UI.settings.insetRelativeWidth)*UI.settings.windowDuration-0.005,(y_data-ylim1(1))/diff(ylim1)*UI.settings.insetRelativeHeight+(0.985-UI.settings.insetRelativeHeight), 'HitTest','off','Color', markerColor,'Marker','o','LineStyle','-','linewidth',2,'MarkerFaceColor',markerColor,'MarkerEdgeColor',markerColor)
            k_channels = k_channels + numel(channels);
        end
        text(UI.plot_axis1,(1-UI.settings.insetRelativeWidth)*UI.settings.windowDuration-0.005,(0.986-UI.settings.insetRelativeHeight),[' ', num2str(ylim1(1),3),char(181),'V'],'FontWeight', 'Bold','VerticalAlignment', 'bottom','HorizontalAlignment','left','color',UI.settings.primaryColor,'FontSize',12)
        text(UI.plot_axis1,(1-UI.settings.insetRelativeWidth)*UI.settings.windowDuration-0.005,0.984,[' ', num2str(ylim1(2),3),char(181),'V'],'FontWeight', 'Bold','VerticalAlignment', 'top','HorizontalAlignment','left','color',UI.settings.primaryColor,'FontSize',12)
    end

    function plotTemporalStates(t1,t2)
        % Plot states
        if isfield(data,'states')
            if isfield(data.states.(UI.settings.statesData),'ints')
                states1  = data.states.(UI.settings.statesData).ints;
            else
                states1  = data.states.(UI.settings.statesData);
            end
            stateNames = fieldnames(states1);
            clr_states = eval([UI.settings.colormap,'(',num2str(numel(stateNames)),')']);
            addLegend(['States: ' UI.settings.statesData])
            for jj = 1:numel(stateNames)
                if size(states1.(stateNames{jj}),2) == 2 && size(states1.(stateNames{jj}),1) > 0
                    idx = (states1.(stateNames{jj})(:,1)<t2 & states1.(stateNames{jj})(:,2)>t1);
                    if any(idx)
                        statesData = states1.(stateNames{jj})(idx,:)-t1;
                        statesData(statesData<0) = 0; statesData(statesData>t2-t1) = t2-t1;
                        p1 = patch(double([statesData,flip(statesData,2)])',[UI.dataRange.states(1);UI.dataRange.states(1);UI.dataRange.states(2);UI.dataRange.states(2)]*ones(1,size(statesData,1)),clr_states(jj,:),'EdgeColor',clr_states(jj,:),'HitTest','off');
                        alpha(p1,0.3);
                        addLegend(stateNames{jj},clr_states(jj,:)*0.8);
                    else
                        addLegend(stateNames{jj},[0.5, 0.5, 0.5]);
                    end
                end
            end
        end
    end

    function viewSessionMetaData(~,~)
        % Opens the gui_session for the current session to editing metadata
        [session1,~,statusExit] = gui_session(data.session);
        if statusExit
            data.session = session1;
            initData(basepath,basename);
            initTraces;
            uiresume(UI.fig);
        end
    end

    function openSessionDirectory(~,~)
        % opens the basepath in the file browser
        if ispc
            winopen(basepath);
        elseif ismac
            syscmd = ['open ', basepath, ' &'];
            system(syscmd);
        else
            filebrowser;
        end
    end

    function defineGroupData(~,~)
        if isfield(data,'cell_metrics')
            [data.cell_metrics,UI] = dialog_metrics_groupData(data.cell_metrics,UI);
            % Group data
            % Filters tagged cells ('tags','groups','groundTruthClassification')
            if ~isempty(UI.groupData1)
                dataTypes = {'tags','groups','groundTruthClassification'};
                filter_pos = [];
                filter_neg = [];
                for jjj = 1:numel(dataTypes)
                    if isfield(UI.groupData1,dataTypes{jjj}) && isfield(UI.groupData1.(dataTypes{jjj}),'plus_filter') && any(struct2array(UI.groupData1.(dataTypes{jjj}).plus_filter))
                        if isfield(UI.groupData1,dataTypes{jjj}) && isfield(UI.groupData1.(dataTypes{jjj}),'plus_filter')
                            fields1 = fieldnames(UI.groupData1.(dataTypes{jjj}).plus_filter);
                            for jj = 1:numel(fields1)
                                if UI.groupData1.(dataTypes{jjj}).plus_filter.(fields1{jj}) == 1 && isfield(data.cell_metrics.(dataTypes{jjj}),fields1{jj})  && ~isempty(data.cell_metrics.(dataTypes{jjj}).(fields1{jj}))
                                    filter_pos = [filter_pos,data.cell_metrics.(dataTypes{jjj}).(fields1{jj})];
                                end
                            end
                        end
                    end
                    if isfield(UI.groupData1,dataTypes{jjj}) && isfield(UI.groupData1.(dataTypes{jjj}),'minus_filter') && any(struct2array(UI.groupData1.(dataTypes{jjj}).minus_filter))
                        if isfield(UI.groupData1,dataTypes{jjj}) && isfield(UI.groupData1.(dataTypes{jjj}),'minus_filter')
                            fields1 = fieldnames(UI.groupData1.(dataTypes{jjj}).minus_filter);
                            for jj = 1:numel(fields1)
                                if UI.groupData1.(dataTypes{jjj}).minus_filter.(fields1{jj}) == 1 && isfield(data.cell_metrics.(dataTypes{jjj}),fields1{jj}) && ~isempty(data.cell_metrics.(dataTypes{jjj}).(fields1{jj}))
                                    filter_neg = [filter_neg,data.cell_metrics.(dataTypes{jjj}).(fields1{jj})];
                                end
                            end
                        end
                    end
                end
                if ~isempty(filter_neg)
                    UI.params.subsetGroups = setdiff(UI.params.subsetGroups,filter_neg);
                end
                if ~isempty(filter_pos)
                    UI.params.subsetGroups = intersect(UI.params.subsetGroups,filter_pos);
                end
            else
                UI.params.subsetGroups = 1:data.spikes.numcells;
            end
        end
    end
    
%     function openCellExplorer(~,~)
%         % Opens CellExplorer for the current session
%         if ~isfield(data,'cell_metrics') && exist(fullfile(basepath,[basename,'.cell_metrics.cellinfo.mat']),'file')
%             data.cell_metrics = loadCellMetrics('session',data.session);
%         elseif ~exist(fullfile(basepath,[basename,'.cell_metrics.cellinfo.mat']),'file')
%             UI.panel.cell_metrics.useMetrics.Value = 0;
%             MsgLog('Cell_metrics does not exist',4);
%             return
%         end
%         data.cell_metrics = CellExplorer('metrics',data.cell_metrics);
%         toggleMetrics
%         uiresume(UI.fig);
%     end
    
    function AboutDialog(~,~)
        if ismac
            fig_size = [50, 50, 300, 130];
            pos_image = [20 72 268 46];
            pos_text = 110;
        else
            fig_size = [50, 50, 320, 150];
            pos_image = [20 88 268 46];
            pos_text = 110;
        end
        
        AboutWindow.dialog = figure('Position', fig_size,'Name','About NeuroScope2', 'MenuBar', 'None','NumberTitle','off','visible','off', 'resize', 'off'); movegui(AboutWindow.dialog,'center'), set(AboutWindow.dialog,'visible','on')
        if isdeployed
            logog_path = '';
        else
            [logog_path,~,~] = fileparts(which('CellExplorer.m'));
        end
        [img, ~, alphachannel] = imread(fullfile(logog_path,'logo_NeuroScope2.png'));
        image(img, 'AlphaData', alphachannel,'ButtonDownFcn',@openWebsite);
        AboutWindow.image = gca;
        set(AboutWindow.image,'Color','none','Units','Pixels') , hold on, axis off
        AboutWindow.image.Position = pos_image;
        text(0,pos_text,{'\bfNeuroScope2\rm - part of CellExplorer','By Peter Petersen.', 'Developed in the Buzsaki laboratory at NYU, USA.','\bf\color[rgb]{0. 0.2 0.5}https://CellExplorer.org/\rm'},'HorizontalAlignment','left','VerticalAlignment','top','ButtonDownFcn',@openWebsite, 'interpreter','tex')
    end
    
    function exitNeuroScope2(~,~)
    	close(UI.fig);
    end
        
    function DatabaseSessionDialog(~,~)
        % Load sessions from the database.
        % Dialog is shown with sessions from the database with calculated cell metrics.
        % Then selected session is loaded from the database
        
        [basenames,basepaths] = gui_db_sessions(basename);
        try
            if ~isempty(basenames)
                data = [];
                basepath = basepaths{1};
                basename = basenames{1};
                initData(basepath,basename);
                initTraces;
                uiresume(UI.fig);
            end
        catch
            MsgLog(['Failed to loaded session: ' basename],4)
        end
    end
    
    function editDBcredentials(~,~)
        edit db_credentials.m
    end
    
    function editDBrepositories(~,~)
        edit db_local_repositories.m
    end
    
    function openSessionInWebDB(~,~)
        % Opens the current session in the Buzsaki lab web database
        web(['https://buzsakilab.com/wp/sessions/?frm_search=', basename],'-new','-browser')
    end

    function showAnimalInWebDB(~,~)
        % Opens the current animal in the Buzsaki lab web database
        if isfield(data.session.animal,'name')
            web(['https://buzsakilab.com/wp/animals/?frm_search=', data.session.animal.name],'-new','-browser')
        else
            web('https://buzsakilab.com/wp/animals/','-new','-browser')
        end
    end

    function keyPress(~, event)
        % Handles keyboard shortcuts
        UI.settings.stream = false;

        if isempty(event.Modifier)

            switch event.Key
                case 'rightarrow'
                    advance(0.25)
                case 'leftarrow'
                    back(0.25)
                case 'm'
                    % Hide/show menubar
                    ShowHideMenu
                case 'q'
                    increaseWindowsSize
                case 'a'
                    decreaseWindowsSize
                case 'g'
                    goToTimestamp
                case 's'
                    toggleSpikes
                case 'e'
                    showEvents
                case 't'
                    showTimeSeries
                case 'numpad0'
                    UI.t0 = 0;
                    uiresume(UI.fig);
                case 'decimal'
                    UI.t0 = UI.t_total-UI.settings.windowDuration;
                    uiresume(UI.fig);
                case 'backspace'
                    if numel(UI.t0_track)>1
                        UI.t0_track(end) = [];
                    end
                    UI.track = false;
                    UI.t0 = UI.t0_track(end);
                    uiresume(UI.fig);
                case 'uparrow'
                    increaseAmplitude
                case 'downarrow'
                    decreaseAmplitude
                case 'c'
                    answer = inputdlg('Provide channels to highlight','Highlighting');
                    if ~isempty(answer) & isnumeric(str2num(answer{1})) & all(str2num(answer{1})>0)
                        highlightTraces(str2num(answer{1}),[]);
                    end
                case 'h'
                    HelpDialog
                case 'period'
                    nextEvent
                case 'comma'
                    previousEvent
                case 'f'
                    flagEvent
                case 'l'
                    addEvent
                case 'slash'
                    randomEvent
                case 'control'
                    UI.settings.normalClick = false;
            end

        elseif strcmp(event.Modifier,'shift')
            
            switch event.Key
                case 'space'
                    streamData
                case 'rightarrow'
                    advance(1)
                case 'leftarrow'
                    back(1)
                case 'period'
                    nextPowerEvent
                case 'comma'
                    previousPowerEvent
                case 'slash'
                    maxPowerEvent
                case 'l'
                    minPowerEvent
                case 'f'
                    flagEvent
            end

        elseif strcmp(event.Modifier,'control')

            UI.settings.normalClick = false;
            switch event.Key
                case 'space'
                    streamData_end_of_file
            end

        elseif strcmp(event.Modifier,'alt')

            switch event.Key
                case 'rightarrow'
                    advance(0.1)
                case 'leftarrow'
                    back(0.1)
            end

        end
    end
    
    function keyRelease(~, event)
        if strcmp(event.Key,'control')
            UI.settings.normalClick = true;
        end
    end
    
    function setChannelOrder(src,~)
        UI.menu.display.channelOrder.option(UI.settings.channelOrder).Checked = 'off';
        UI.settings.channelOrder = src.Position;
        UI.menu.display.channelOrder.option(UI.settings.channelOrder).Checked = 'on';
        initTraces
        uiresume(UI.fig);
    end
    
    function ShowChannelNumbers(~,~)
        UI.settings.showChannelNumbers = ~UI.settings.showChannelNumbers;
        if UI.settings.showChannelNumbers
            UI.menu.display.showChannelNumbers.Checked = 'on';
        else
            UI.menu.display.showChannelNumbers.Checked = 'off';
        end
        initTraces
        resetZoom
        uiresume(UI.fig);
    end
    
    function setStickySelection(~,~)
        UI.settings.stickySelection = ~UI.settings.stickySelection;
        if UI.settings.stickySelection
            UI.menu.display.stickySelection.Checked = 'on';
        else
            UI.menu.display.stickySelection.Checked = 'off';
        end
    end
        
    function resetZoomOnNavigation(~,~)
        UI.settings.resetZoomOnNavigation = ~UI.settings.resetZoomOnNavigation;
        if UI.settings.resetZoomOnNavigation
            UI.menu.display.resetZoomOnNavigation.Checked = 'on';
        else
            UI.menu.display.resetZoomOnNavigation.Checked = 'off';
        end
    end
    
    function showScalebar(~,~)
        UI.settings.showScalebar = ~UI.settings.showScalebar;
        if UI.settings.showScalebar
            UI.menu.display.showScalebar.Checked = 'on';
        else
            UI.menu.display.showScalebar.Checked = 'off';
        end
        uiresume(UI.fig);
    end

    function showTimeScalebar(~,~)
        UI.settings.showTimeScalebar = ~UI.settings.showTimeScalebar;
        if UI.settings.showTimeScalebar
            UI.menu.display.showTimeScalebar.Checked = 'on';
        else
            UI.menu.display.showTimeScalebar.Checked = 'off';
        end
        uiresume(UI.fig);
    end
    
    function narrowPadding(~,~)
        UI.settings.narrowPadding = ~UI.settings.narrowPadding;
        if UI.settings.narrowPadding
            UI.settings.ephys_padding = 0.015;
            UI.menu.display.narrowPadding.Checked = 'on';
        else
            UI.settings.ephys_padding = 0.05;
            UI.menu.display.narrowPadding.Checked = 'off';
        end
        initTraces
        uiresume(UI.fig);
    end
    
    function plotStyleDynamicRange(~,~)
        UI.settings.plotStyleDynamicRange = ~UI.settings.plotStyleDynamicRange;
        if UI.settings.plotStyleDynamicRange
            UI.menu.display.plotStyleDynamicRange.Checked = 'on';
        else
            UI.menu.display.plotStyleDynamicRange.Checked = 'off';
        end
        uiresume(UI.fig);
    end
    
    function detectedEventsBelowTrace(~,~)
        UI.settings.detectedEventsBelowTrace = ~UI.settings.detectedEventsBelowTrace;
        if UI.settings.detectedEventsBelowTrace
            UI.menu.display.detectedEventsBelowTrace.Checked = 'on';
        else
            UI.menu.display.detectedEventsBelowTrace.Checked = 'off';
        end
        initTraces
        uiresume(UI.fig);
    end
    
    function detectedSpikesBelowTrace(~,~)
        UI.settings.detectedSpikesBelowTrace = ~UI.settings.detectedSpikesBelowTrace;
        if UI.settings.detectedSpikesBelowTrace
            UI.menu.display.detectedSpikesBelowTrace.Checked = 'on';
        else
            UI.menu.display.detectedSpikesBelowTrace.Checked = 'off';
        end
        initTraces
        uiresume(UI.fig);
    end
    
    function detectedSpikesPolarity(~,~)
        UI.settings.spikesDetectionPolarity = ~UI.settings.spikesDetectionPolarity;
        if UI.settings.spikesDetectionPolarity
            UI.menu.display.spikesDetectionPolarity.Checked = 'on';
        else
            UI.menu.display.spikesDetectionPolarity.Checked = 'off';
        end
        initTraces
        uiresume(UI.fig);
    end
    
    function showDetectedSpikeWaveforms(~,~)
        UI.settings.showDetectedSpikeWaveforms = ~UI.settings.showDetectedSpikeWaveforms;
        if UI.settings.showDetectedSpikeWaveforms && isfield(data.session.extracellular,'chanCoords')
            UI.menu.display.showDetectedSpikeWaveforms.Checked = 'on';
        elseif UI.settings.showDetectedSpikeWaveforms
            UI.menu.display.showDetectedSpikeWaveforms.Checked = 'off';
            UI.settings.showDetectedSpikeWaveforms = false;
            MsgLog('ChanCoords have not been defined for this session',4)
        else
            UI.menu.display.showDetectedSpikeWaveforms.Checked = 'off';
        end
        
        initTraces
        uiresume(UI.fig);
    end
    
    function toggleColorDetectedSpikesByWidth(~,~)
        UI.settings.colorDetectedSpikesByWidth = ~UI.settings.colorDetectedSpikesByWidth;

        if UI.settings.colorDetectedSpikesByWidth
            answer = inputdlg('Max trough-to-peak of interneurons (ms)','Waveform width boundary', [1 50],{num2str(UI.settings.interneuronMaxWidth)});
            if ~isempty(answer) && isnumeric(str2num(answer{1})) && str2num(answer{1}) > 0
                UI.settings.interneuronMaxWidth = str2num(answer{1});
                UI.menu.display.colorDetectedSpikesByWidth.Checked = 'on';
                UI.settings.showDetectedSpikeWaveforms = true;
                UI.menu.display.showDetectedSpikeWaveforms.Checked = 'on';
            else
                UI.settings.colorDetectedSpikesByWidth = false;
                UI.menu.display.colorDetectedSpikesByWidth.Checked = 'off';
            end
        else
            UI.menu.display.colorDetectedSpikesByWidth.Checked = 'off';
        end
        initTraces
        uiresume(UI.fig);
    end
    
    function showDetectedSpikesPCAspace(~,~)
        UI.settings.showDetectedSpikesPCAspace = ~UI.settings.showDetectedSpikesPCAspace;
        if UI.settings.showDetectedSpikesPCAspace
            UI.menu.display.showDetectedSpikesPCAspace.Checked = 'on';
        else
            UI.menu.display.showDetectedSpikesPCAspace.Checked = 'off';
        end
        initTraces
        uiresume(UI.fig);
    end
    
    function showDetectedSpikesAmplitudeDistribution(~,~)
        UI.settings.showDetectedSpikesAmplitudeDistribution = ~UI.settings.showDetectedSpikesAmplitudeDistribution;
        if UI.settings.showDetectedSpikesAmplitudeDistribution
            UI.menu.display.showDetectedSpikesAmplitudeDistribution.Checked = 'on';
        else
            UI.menu.display.showDetectedSpikesAmplitudeDistribution.Checked = 'off';
        end
        initTraces
        uiresume(UI.fig);
    end

    function showDetectedSpikesCountAcrossChannels(~,~)
        UI.settings.showDetectedSpikesCountAcrossChannels = ~UI.settings.showDetectedSpikesCountAcrossChannels;
        if UI.settings.showDetectedSpikesCountAcrossChannels
            UI.menu.display.showDetectedSpikesCountAcrossChannels.Checked = 'on';
        else
            UI.menu.display.showDetectedSpikesCountAcrossChannels.Checked = 'off';
        end
        initTraces
        uiresume(UI.fig);
    end


    

    function showDetectedSpikesPopulationRate(~,~)
        UI.settings.showDetectedSpikesPopulationRate = ~UI.settings.showDetectedSpikesPopulationRate;
        if UI.settings.showDetectedSpikesPopulationRate
            UI.menu.display.showDetectedSpikesPopulationRate.Checked = 'on';
        else
            UI.menu.display.showDetectedSpikesPopulationRate.Checked = 'off';
        end
        initTraces
        uiresume(UI.fig);
    end
    
    function toggleRMSnoiseInset(~,~)
        if UI.panel.RMSnoiseInset.showRMSnoiseInset.Value == 1
            UI.settings.plotRMSnoiseInset = true;
        else
            UI.settings.plotRMSnoiseInset = false;
        end        
        UI.settings.plotRMSnoise_apply_filter = UI.panel.RMSnoiseInset.filter.Value;
        if UI.panel.RMSnoiseInset.filter.Value == 3
            UI.settings.plotRMSnoise_lowerBand = str2num(UI.panel.RMSnoiseInset.lowerBand.String);
            UI.settings.plotRMSnoise_higherBand = str2num(UI.panel.RMSnoiseInset.higherBand.String);
        end
        
        uiresume(UI.fig);
    end
    
    function toggleInstantaneousMetrics(~,~)
        numeric_gt_0 = @(n) ~isempty(n) && isnumeric(n) && (n > 0); % numeric and greater than 0
        numeric_gt_oe_0 = @(n) ~isempty(n) && isnumeric(n) && (n >= 0); % Numeric and greater than or equal to 0
        
        if UI.panel.instantaneousMetrics.showPower.Value == 1
            UI.settings.instantaneousMetrics.showPower = true;
        else
            UI.settings.instantaneousMetrics.showPower = false;
        end
        
        if UI.panel.instantaneousMetrics.showSignal.Value == 1
            UI.settings.instantaneousMetrics.showSignal = true;
        else
            UI.settings.instantaneousMetrics.showSignal = false;
        end
        
        if UI.panel.instantaneousMetrics.showPhase.Value == 1
            UI.settings.instantaneousMetrics.showPhase = true;
        else
            UI.settings.instantaneousMetrics.showPhase = false;
        end
        
        % Channel to use
        channelnumber = str2num(UI.panel.instantaneousMetrics.channel.String);
        if isnumeric(channelnumber) && channelnumber>0 && channelnumber<=data.session.extracellular.nChannels
            UI.settings.instantaneousMetrics.channel = channelnumber;
            UI.settings.instantaneousMetrics.show = true;
        else
            UI.settings.instantaneousMetrics.show = false;
            MsgLog('The channel is not valid',4);
        end
        
        if UI.settings.instantaneousMetrics.showPower || UI.settings.instantaneousMetrics.showSignal || UI.settings.instantaneousMetrics.showPhase
            UI.settings.instantaneousMetrics.show = true;
        else
            UI.settings.instantaneousMetrics.show = false;
        end
                
        % Frequency range and step size
        UI.settings.instantaneousMetrics.lowerBand = str2num(UI.panel.instantaneousMetrics.lowerBand.String);
        UI.settings.instantaneousMetrics.higherBand = str2num(UI.panel.instantaneousMetrics.higherBand.String);
        
        initTraces
        uiresume(UI.fig);
    end
    
    function togglePlayAudio(~,~)
        UI.settings.stream = false;
        gain_values = [1,2,5,10,20];
        UI.settings.audioGain = gain_values(UI.panel.audio.gain.Value);
        
        [channel_out_left,channel_valid_left] = validate_channel(UI.panel.audio.leftChannel.String);
        if ~channel_valid_left
            UI.panel.audio.leftChannel.String = num2str(channel_out_left);
        end
        
        [channel_out_right,channel_valid_right] = validate_channel(UI.panel.audio.rightChannel.String);
        if ~channel_valid_right
            UI.panel.audio.leftChannel.String = num2str(channel_out_right);
        end
        
        UI.settings.audioChannels = [channel_out_left,channel_out_right];
        
        if UI.panel.audio.playAudio.Value == 1
            if ~isempty(UI.settings.audioChannels)
                initAudioDeviceWriter
                UI.settings.audioPlay = true;
            else
                UI.panel.audio.playAudio.Value = 0;
                UI.settings.audioPlay = false;
                MsgLog('Please set audio channels first',4);
            end
        else
            UI.settings.audioPlay = false;
        end
    end
    
    function show_CSD(~,~)
        if UI.panel.csd.showCSD.Value == 1
            UI.settings.CSD.show = true;
        else
            UI.settings.CSD.show = false;
        end
        uiresume(UI.fig);
    end
    
    function removeDC(~,~)
        UI.settings.removeDC = ~UI.settings.removeDC;
        if UI.settings.removeDC
            UI.menu.display.removeDC.Checked = 'on';
        else
            UI.menu.display.removeDC.Checked = 'off';
        end
        uiresume(UI.fig);
    end

    function medianFilter(~,~)
        UI.settings.medianFilter = ~UI.settings.medianFilter;
        if UI.settings.medianFilter
            UI.menu.display.medianFilter.Checked = 'on';
        else
            UI.menu.display.medianFilter.Checked = 'off';
        end
        uiresume(UI.fig);
    end

    function ShowHideMenu(~,~)
        % Hide/show menubar
        if UI.settings.displayMenu == 0
            set(UI.fig, 'MenuBar', 'figure')
            UI.settings.displayMenu = 1;
            UI.menu.display.showHideMenu.Checked = 'On';
            fieldmenus = fieldnames(UI.menu);
            fieldmenus(strcmpi(fieldmenus,'NeuroScope2')) = [];
            for i = 1:numel(fieldmenus)
                UI.menu.(fieldmenus{i}).topMenu.Visible = 'off';
            end
            MsgLog('Regular MATLAB menubar shown. Press M to regain the NeuroScope2 menubar',2);
        else
            set(UI.fig, 'MenuBar', 'None')
            UI.settings.displayMenu = 0;
            UI.menu.display.showHideMenu.Checked = 'Off';
            fieldmenus = fieldnames(UI.menu);
            for i = 1:numel(fieldmenus)
                UI.menu.(fieldmenus{i}).topMenu.Visible = 'on';
            end
        end
    end
    
    function HelpDialog(~,~)
        if ismac; scs  = 'Cmd + '; else; scs  = 'Ctrl + '; end
        shortcutList = { 
            '','<html><b>Mouse actions</b></html>';
            'Left mouse button','Pan traces'; 
            'Right mouse button','Rubber band tool for zooming and measurements';
            'Middle button','Highlight ephys trace';
            'Middle button+shift','Highlight unit spike raster';
            'Double click','Reset zoom';
            'Scroll in','Zoom in';
            'Scroll out','Zoom out';
            
            '   ',''; 
            '','<html><b>Navigation</b></html>';
            '> (right arrow)','Forward in time (quarter window length)'; 
            '< (left arrow)','Backward in time (quarter window length)';
            'shift + > (right arrow)','Forward in time (full window length)'; 
            'shift + < (left arrow)','Backward in time (full window length)';
            'alt + > (right arrow)','Forward in time (a tenth window length)'; 
            'alt + < (left arrow)','Backward in time (a tenth window length)';
            'G','Go to timestamp';
            'Numpad0','Go to t = 0s'; 
            'Backspace','Go to previous time point'; 
            
            '   ',''; 
            '','<html><b>Display settings</b></html>';
            [char(94) ' (up arrow)'],'increase ephys amplitude'; 
            'v (down arrow)','Decrease ephys amplitude';
            'Q','Increase window duration'; 
            'A','Decrease window duration';
            'C','Highlight ephys channel(s)';
                        
            '   ',''; 
            '','<html><b>Data streaming</b></html>';
            'shift + space','Stream data from current time'; 
            'ctrl + space','Stream data from end of file'; 
            
            '   ',''; 
            '','<html><b>Mat files</b></html>';
            'S','Toggle spikes';
            'E','Toggle events';
            'T','Toggle timeseries';
            '. (dot)','Go to next event';
            ', (comma)','Go to previous event';
            '/ (slash/period)','Go to random event';
            'F','Flag event';
            'L','Add/delete events';
            
            '   ',''; 
            '','<html><b>Other shortcuts</b></html>';
            'H','View mouse and keyboard shortcuts (this page)';
            [scs,'O'],'Open session from file'; 
            [scs,'C'],'Open the file directory of the current session'; 
            [scs,'D'],'Opens session from the Buzsaki lab database';
            [scs,'V'],'Visit the CellExplorer website in your browser';
            '',''; '','<html><b>Visit the CellExplorer website for further help and documentation</html></b>'; };
        if ismac
            dimensions = [450,(size(shortcutList,1)+1)*17.5];
        else
            dimensions = [450,(size(shortcutList,1)+1)*18.5];
        end
        HelpWindow.dialog = figure('Position', [300, 300, dimensions(1), dimensions(2)],'Name','Mouse and keyboard shortcuts', 'MenuBar', 'None','NumberTitle','off','visible','off'); movegui(HelpWindow.dialog,'center'), set(HelpWindow.dialog,'visible','on')
        HelpWindow.sessionList = uitable(HelpWindow.dialog,'Data',shortcutList,'Position',[1, 1, dimensions(1)-1, dimensions(2)-1],'ColumnWidth',{100 345},'columnname',{'Shortcut','Action'},'RowName',[],'ColumnEditable',[false false],'Units','normalized');
    end
    
    
    function streamDataButtons
        if ~UI.settings.stream
            streamData
        else
            UI.settings.stream = false;
        end
    end
    
    function streamDataButtons2
        if ~UI.settings.stream
            streamData_end_of_file
        else
            UI.settings.stream = false;
        end
    end
    
    function streamData
        % Streams  data from t0, updating traces twice per window duration (UI.settings.replayRefreshInterval)
        if ~UI.settings.stream
            UI.settings.stream = true;
            UI.settings.fileRead = 'bof';
            UI.buttons.play1.String = [char(9646) char(9646)];
            UI.elements.lower.performance.String = '  Streaming...';
            n_streaming = 0;
            if UI.settings.audioPlay
            	UI.settings.playAudioFirst = true;
            else
                UI.settings.playAudioFirst = false;
            end
            streamToc = 0;
            streamToc_extra = 0;            
            
            while UI.settings.stream
                streamTic = tic;
                if streamToc > UI.settings.windowDuration*UI.settings.replayRefreshInterval || streamToc == 0
                    replayRefreshInterval = 1;
                else
                    replayRefreshInterval = UI.settings.replayRefreshInterval;
                end
                
                UI.t0 = UI.t0+replayRefreshInterval*UI.settings.windowDuration;
                UI.t0 = max([0,min([UI.t0,UI.t_total-UI.settings.windowDuration])]);
                if ~ishandle(UI.fig) ||  (UI.fid.ephys == -1 && UI.settings.plotStyle ~= 4)
                    return
                end
                
                % playAudioWithTrace
                if UI.settings.audioPlay && n_streaming == 0
                    samples = 1:round(UI.settings.replayRefreshInterval*ephys.nSamples);
                    if all(ismember(UI.settings.audioChannels,UI.channelOrder))
                        deviceWriter(UI.settings.audioGain*ephys.traces(samples,UI.settings.audioChannels)); 
                    elseif sum(ismember(UI.settings.audioChannels,UI.channelOrder))>0 && length(UI.settings.audioChannels)==2
                        audioChannels = UI.settings.audioChannels(ismember(UI.settings.audioChannels,UI.channelOrder));
                        deviceWriter(UI.settings.audioGain*ephys.traces(samples,[audioChannels,audioChannels])); 
                    end
                end
                
                if UI.settings.playAudioFirst
                    load_ephys_data
                end
                
                % playAudioWithTrace
                if UI.settings.audioPlay
                    samples = 1:round(replayRefreshInterval*ephys.nSamples);
                    if all(ismember(UI.settings.audioChannels,UI.channelOrder))
                        deviceWriter(UI.settings.audioGain*ephys.traces(samples,UI.settings.audioChannels)); 
                    elseif sum(ismember(UI.settings.audioChannels,UI.channelOrder))>0 && length(UI.settings.audioChannels)==2
                        audioChannels = UI.settings.audioChannels(ismember(UI.settings.audioChannels,UI.channelOrder));
                        deviceWriter(UI.settings.audioGain*ephys.traces(samples,[audioChannels,audioChannels])); 
                    end
                    UI.settings.deviceWriterActive = true;
                    n_streaming = n_streaming+1;
                end
                
                plotData
                
                if UI.settings.audioPlay
                    audioChannels = UI.settings.audioChannels(ismember(UI.settings.audioChannels,UI.channelOrder));
                    highlightTraces(audioChannels,UI.settings.primaryColor);
                end

                % Updating UI text and slider
                UI.elements.lower.time.String = num2str(UI.t0);
                setTimeText(UI.t0)
                UI.streamingText = text(UI.plot_axis1,UI.settings.windowDuration/2,1,['Streaming: ', num2str(UI.settings.windowDuration*replayRefreshInterval),' sec intervals'],'FontWeight', 'Bold','VerticalAlignment', 'top','HorizontalAlignment','center','color',UI.settings.primaryColor,'HitTest','off');
                

                drawnow
                streamToc = toc(streamTic)-min([0,streamToc_extra]);

                if UI.settings.windowDuration*replayRefreshInterval-streamToc > 0
                    pauseBins = ones(1,10) * 0.1 * (UI.settings.windowDuration*replayRefreshInterval-streamToc);
                else
                    pauseBins = [];
                end
                
                if ~isempty(pauseBins)
                    for i = 1:numel(pauseBins)
                        if UI.settings.stream
                            pause(pauseBins(i))
                        end
                    end
                end
                
                if UI.t0 == UI.t_total-UI.settings.windowDuration
                    UI.settings.stream = false;
                end

                streamToc_extra = UI.settings.windowDuration*replayRefreshInterval-toc(streamTic);
            end
            UI.elements.lower.performance.String = '';
        end
        UI.settings.fileRead = 'bof';
        if ishandle(UI.streamingText)
            delete(UI.streamingText)
        end
        
        if UI.t0 == UI.t_total-UI.settings.windowDuration
            UI.streamingText = text(UI.plot_axis1,UI.settings.windowDuration/2,1,'Streaming stopped: End of file','FontWeight', 'Bold','VerticalAlignment', 'top','HorizontalAlignment','center','color',UI.settings.primaryColor,'HitTest','off');
        end
        
        UI.buttons.play1.String = char(9654);
        UI.buttons.play2.String = [char(9655) char(9654)];
        if UI.settings.audioPlay
            release(deviceWriter)
            UI.settings.deviceWriterActive = false;
            UI.settings.playAudioFirst = false;
        end        
    end
    
    function streamData_end_of_file
        % Stream from the end of the file, updating twice per window duration
        if ~UI.settings.stream
            UI.settings.stream = true;
            UI.settings.fileRead = 'eof';
            sliderMovedManually = false;
            UI.elements.lower.slider.Value = 100;
            while UI.settings.stream
                UI.t0 = UI.t_total-UI.settings.windowDuration;
                if ~ishandle(UI.fig)
                    return
                end
                plotData
                UI.streamingText = text(UI.plot_axis1,UI.settings.windowDuration/2,1,'Streaming: end of file','FontWeight', 'Bold','VerticalAlignment', 'top','HorizontalAlignment','center','color',UI.settings.primaryColor,'HitTest','off');
                UI.buttons.play2.String = [char(9646) char(9646)];
                for i = 1:10
                    if UI.settings.stream
                        pause(0.05*UI.settings.windowDuration)
                    end
                end
            end
        end
        UI.settings.fileRead = 'bof';
        if ishandle(UI.streamingText)
            delete(UI.streamingText)
        end
        UI.buttons.play1.String = char(9654);
        UI.buttons.play2.String = [char(9655) char(9654)];
    end

    function streamData_to_video(parameters)
        % parameters
        %  .profile
        %  .framerate
        %  .duration
        %  .playback_speed
        %  .full_file_name

        n_frames = parameters.duration*parameters.framerate;

        writerObj = VideoWriter(parameters.full_file_name, parameters.profile);
        %writerObj.Quality = 100;
        switch parameters.playback_speed
            case 'x/10'
                playback_speed = 0.1;
            case 'x/5'
                playback_speed = 0.2;
            case 'x/4'
                playback_speed = 0.25;
            case 'x/2'
                playback_speed = 0.5;
            case '1x'
                playback_speed = 1;
            case '2x'
                playback_speed = 2;
            case '4x'
                playback_speed = 4;
        end

        writerObj.FrameRate = round(parameters.framerate*playback_speed);

        open(writerObj);

        % Stream to video
        if ~UI.settings.stream
            UI.plot_axis1.XColor = UI.settings.background;
            UI.settings.stream = true;
            UI.settings.fileRead = 'bof';
            for i = 1:n_frames
                UI.t0 = UI.t0+UI.settings.windowDuration/parameters.framerate;
                UI.t0 = max([0,min([UI.t0,UI.t_total-UI.settings.windowDuration])]);
                if ~ishandle(UI.fig) ||  (UI.fid.ephys == -1 && UI.settings.plotStyle ~= 4) || ~UI.settings.stream
                    UI.settings.stream = false;
                    return
                end

                plotData
                UI.elements.lower.performance.String = ['Generating videoframes: ', num2str(i), '/', num2str(n_frames)];
                drawnow
                frame = getframe(UI.plot_axis1);
                writeVideo(writerObj,frame);
            end
        end        
        close(writerObj);
        UI.plot_axis1.XColor = UI.settings.primaryColor;
    end
    
    function benchmarkStream(~,~)
        benchmarkChannelCount(true)
        benchmarkDuration(true)
    end
    
    function initAudioDeviceWriter(~,~)
        if isToolboxInstalled('DSP System Toolbox') || isToolboxInstalled('Audio Toolbox')
            if UI.settings.plotStyle == 4
                sr = data.session.extracellular.srLfp;
            else
                sr = data.session.extracellular.sr;
            end
            deviceWriter = audioDeviceWriter('SampleRate',sr,'SupportVariableSizeInput',true);
            SamplesPerFrame = round(UI.settings.replayRefreshInterval*sr);
            NumChannels = numel(UI.settings.audioChannels);
            setup(deviceWriter,zeros(SamplesPerFrame,NumChannels))
            UI.settings.audioPlay = true;
            
        else
            MsgLog('Audio streaming requires the DSP System Toolbox or the Audio Toolbox. Please install one of the toolboxes.',2);
            UI.settings.audioPlay = false;
            UI.panel.audio.playAudio.Value = 0;
            return
        end
    end

    function performTestSuite(~,~)
        disp('Performing test suite...')
        TestSuite_tic = tic;
        settings_preTest = UI.settings;
        
        UI.forceNewData = true;
        UI.settings.plotStyleDynamicRange = false;
        UI.settings.fileRead = 'bof';
        
        % % % % % % % % % % % % %
        % Ephys traces
        disp('Testing ephys trace functions')
        
        disp('Testing channel count')
        benchmarkChannelCount(false)
        
        % Test window durations 
        disp('Testing window duration')
        benchmarkDuration(false)
        
        UI.settings.plotStyle = 3;
        UI.settings.windowDuration = 1;
        
        % Test amplitudes
        scalingFactor = [1 10 100];
        for j = 1:length(scalingFactor)
            UI.settings.scalingFactor = scalingFactor(j);
            initTraces
            randomize_t0
            plotData
        end
        
        % Test filters
        disp('Testing filters')
        UI.panel.general.filterToggle.Value = 1;
        src.Style='edit';
        
        % Band pass filter
        UI.panel.general.lowerBand.String = '100';
        UI.panel.general.higherBand.String = '200';
        changeTraceFilter(src)
        plotData
        
        % High pass filter
        UI.panel.general.lowerBand.String = '200';
        UI.panel.general.higherBand.String = '';
        changeTraceFilter(src)
        plotData
        
        % Low pass filter
        UI.panel.general.lowerBand.String = '';
        UI.panel.general.higherBand.String = '200';
        changeTraceFilter(src)
        plotData
        
        % Turning filters off
        src.Style='other';
        UI.panel.general.filterToggle.Value = 0;
        changeTraceFilter(src)
        plotData

        % Test electrode group spacing
        UI.settings.extraSpacing = true;
        initTraces
        plotData
        
        UI.settings.extraSpacing = false;
        initTraces
        plotData
        
        % Test plot styles
        disp('Testing plot styles and colors')
        UI.forceNewData = true;
        for i = 1:6
            UI.settings.plotStyle = i;
            initTraces
            for j = 1:10
                randomize_t0
                plotData
            end
        end
        
        UI.settings.plotStyle = 3;
        initTraces
        
        % Test plot colors
        for i = 1:8
            UI.settings.greyScaleTraces = i;
            for j = 1:10
                randomize_t0
                plotData
            end
        end
        UI.settings.greyScaleTraces = 1;
        
        % Test spike detection
        disp('Testing spike detection')
        UI.panel.general.detectSpikes.Value = 1;
        UI.panel.general.detectThreshold.String = '20';
        toogleDetectSpikes
        for j = 1:10
            randomize_t0
            plotData
        end
        
        UI.panel.general.detectThreshold.String = '50';
        toogleDetectSpikes
        for j = 1:10
            randomize_t0
            plotData
        end
        
        % Test waveform extraction for detect spikes 
        showDetectedSpikeWaveforms
        for j = 1:10
            randomize_t0
            plotData
        end
        
        % Show detected spikes below traces
        detectedSpikesBelowTrace
        for j = 1:10
            randomize_t0
            plotData
        end
        
        UI.panel.general.detectSpikes.Value = 0;
        toogleDetectSpikes        
        detectedSpikesBelowTrace
        showDetectedSpikeWaveforms
        
        % Test event detection
        disp('Testing event detection')
        UI.panel.general.detectEvents.Value = 1;
        UI.panel.general.eventThreshold.String = '20';
        toogleDetectEvents
        for j = 1:10
            randomize_t0
            plotData
        end
        
        UI.panel.general.eventThreshold.String = '50';
        toogleDetectEvents
        for j = 1:10
            randomize_t0
            plotData
        end
        
        UI.panel.general.detectEvents.Value = 0;
        toogleDetectEvents
        
        % Remove DC
        UI.settings.removeDC = true;
        for j = 1:10
            randomize_t0
            plotData
        end
        UI.settings.removeDC = false;
        
        % Medial filter
        UI.settings.medianFilter = true;
        for j = 1:10
            randomize_t0
            plotData
        end
        UI.settings.medianFilter = false;
        
        % Test electrode group filter
        for i = 1:size(UI.table.electrodeGroups.Data,1)
            UI.table.electrodeGroups.Data(:,1) = {true};
            UI.table.electrodeGroups.Data{i,1} = false;
            editElectrodeGroups
            for j = 1:10
                randomize_t0
                plotData
            end
            
            UI.table.electrodeGroups.Data(:,1) = {false};
            UI.table.electrodeGroups.Data{i,1} = true;
            editElectrodeGroups
            for j = 1:10
                randomize_t0
                plotData
            end
        end
        UI.table.electrodeGroups.Data(:,1) = {true};
        editElectrodeGroups
        
        % Test Channel filters
        for i = 1:10
            UI.settings.channelList = unique(ceil(rand(1,20)*data.session.extracellular.nChannels));
            initTraces
            for j = 1:2
                randomize_t0
                plotData
            end
        end
        
        UI.settings.channelList = [data.session.extracellular.electrodeGroups.channels{:}];
        initTraces
        
        % Test brain regions filter
        if isfield(data.session,'brainRegions') && ~isempty(data.session.brainRegions)
            brainRegions = fieldnames(data.session.brainRegions);
            for i = 1:length(brainRegions)
                UI.settings.brainRegionsToHide = brainRegions(i);
                initTraces
                for j = 1:10
                    randomize_t0
                    plotData
                end
            end
            UI.settings.brainRegionsToHide = [];
            initTraces
        end
        
        % Test channel coordinates (todo)
        
        % Test channel tags
        for i = 1:size(UI.table.channeltags.Data,1)
            UI.settings.channelTags.highlight = i;
            UI.settings.channelTags.filter = [];
            UI.settings.channelTags.hide = [];            
            initTraces
            randomize_t0
            plotData
            
            UI.settings.channelTags.highlight = [];
            UI.settings.channelTags.filter = i;
            UI.settings.channelTags.hide = [];
            initTraces
            randomize_t0
            plotData
            
            UI.settings.channelTags.highlight = [];
            UI.settings.channelTags.filter = [];
            UI.settings.channelTags.hide = i;
            initTraces
            randomize_t0
            plotData
        end
        UI.settings.channelTags.highlight = [];
        UI.settings.channelTags.filter = [];
        UI.settings.channelTags.hide = [];
        initTraces
        plotData
        
        % Test timeseries: analog and digital
        for i = 1:size(UI.table.timeseriesdata.Data,1)
            evnt.Indices = i;
            evnt.EditData = true;
            src.Data = UI.table.timeseriesdata.Data;
            showIntan(src,evnt)
            
            for j = 1:10
                randomize_t0
                plotData
            end
            
            evnt.Indices = i;
            evnt.EditData = false;
            src.Data = UI.table.timeseriesdata.Data;
            showIntan(src,evnt)
        end
        
        % % % % % % % % % % % % %
        % Spikes
        toggleSpikes
        if UI.panel.spikes.showSpikes.Value==1
            disp('Testing spikes')
            plotData
            
            % Below trace
            UI.panel.spikes.showSpikesBelowTrace.Value = 1;
            showSpikesBelowTrace
            plotData
            
            % Waveforms
            UI.panel.spikes.showSpikeWaveforms.Value = 1;
            showSpikeWaveforms
            plotData
            
            % Spike matrix
            UI.settings.showSpikeMatrix = true;
            for j = 1:10
                randomize_t0
                plotData
            end
            UI.settings.showSpikeMatrix = false;            
            
            % Population dynamics
            UI.panel.spikes.populationRate.Value = 1;
            UI.panel.spikes.populationRateWindow.String = '0.01';
            UI.panel.spikes.populationRateSmoothing.String = '1';
            tooglePopulationRate            
            for j = 1:10
                randomize_t0
                plotData
            end
            
            UI.panel.spikes.populationRateWindow.String = '0.001';
            UI.panel.spikes.populationRateSmoothing.String = '100';
            tooglePopulationRate            
            for j = 1:10
                randomize_t0
                plotData
            end
            
            % Resetting values
            UI.panel.spikes.showSpikesBelowTrace.Value = 0;
            showSpikesBelowTrace
            
            UI.panel.spikes.showSpikeWaveforms.Value = 0;
            showSpikeWaveforms
            
            UI.settings.showSpikeMatrix = false;
        else
            disp('No spikes testing')
        end
        
        % % % % % % % % % % % % %
        % Cell metrics
        toggleMetrics
        if UI.panel.cell_metrics.useMetrics.Value == 1  
            disp('Testing cell metrics')
            
            % Test putative cell type filter
            if ~isempty(UI.listbox.cellTypes.String)
                for i = 1:length(UI.listbox.cellTypes.String)
                    UI.listbox.cellTypes.Value = i;
                    setCellTypeSelectSubset
                    for j = 1:10
                        randomize_t0
                        plotData
                    end
                end
            end
            
            % testing group data
            for i = 1:length(UI.panel.cell_metrics.groupMetric.String)
                UI.params.groupMetric = UI.panel.cell_metrics.groupMetric.String{i};
                for j = 1:10
                    randomize_t0
                    plotData
                end
            end
            % Test cell filter
            
        else
            disp('No cell metrics testing')
        end
        
        UI.panel.spikes.showSpikes.Value=0;
        toggleSpikes
        
        UI.panel.cell_metrics.useMetrics.Value = 0;
        toggleMetrics
        
        UI.panel.spikes.populationRate.Value = 0;
        tooglePopulationRate
        
        % % % % % % % % % % % % %
        % Events
        if isfield(UI.data.detectecFiles,'events') && ~isempty(UI.data.detectecFiles.events)
            for j = 1:length(UI.data.detectecFiles.events)
                UI.settings.eventData = UI.data.detectecFiles.events{j};
                UI.settings.showEvents(j) = true;
                showEvents(j)
                
                if any(UI.settings.showEvents)
                    disp(['Testing events: ', UI.settings.eventData])
                    UI.t0 = data.events.(UI.settings.eventData).time(1)-UI.settings.windowDuration/2;
                    UI.t0 = data.events.(UI.settings.eventData).time(end)-UI.settings.windowDuration/2;
                    
                    % processing_steps
                    UI.settings.processing_steps = true;
                    initTraces
                    randomEvent
                    
                    UI.settings.processing_steps = false;
                    initTraces
                    randomEvent
                    
                    % showEventsBelowTrace
                    UI.settings.showEventsBelowTrace(j) = true;
                    initTraces
                    randomEvent
                    
                    UI.settings.showEventsBelowTrace(j) = false;
                    initTraces
                    randomEvent
                    
                    % showEventsIntervals
                    UI.settings.showEventsIntervals = true;
                    initTraces
                    randomEvent
                    
                    UI.settings.showEventsIntervals = false;
                    initTraces
                    randomEvent
                    
                    flagEvent
                    flagEvent
                    
                    for i = 1:10
                        randomEvent
                    end
                else
                    disp(['Not events testing for: ', UI.settings.eventData])
                end
            end
        else
            disp('No events testing')
        end
        UI.table.events_data.Data(:,4) = {false};
        UI.settings.showEvents(:) = false;
        
        % % % % % % % % % % % % %
        % States
        if ~isempty(UI.panel.states.files.String)
            for j = 1:length(UI.panel.states.files.String)
                UI.panel.states.files.Value = j;
                UI.settings.statesData = UI.panel.states.files.String{UI.panel.states.files.Value};
                setStatesData
                
                if UI.settings.showStates
                    disp(['Testing states: ', UI.settings.statesData])
                    for i = 1:10
                        randomize_t0
                        plotData
                        
                        nextStates
                        plotData
                        
                        previousStates
                        plotData
                    end
                    
                    for i = 1:10
                        UI.panel.states.statesNumber.String = num2str(i);
                        gotoState
                        plotData
                    end
                else
                    disp(['No states testing: ' UI.settings.statesData])
                end
                showStates
            end
        end
        
        % % % % % % % % % % % % %
        % Behavior
        if ~isempty(UI.panel.behavior.files.String)
            UI.panel.behavior.showBehavior.Value = 1;
            for j = 1:length(UI.panel.behavior.files.String)
                UI.panel.behavior.files.Value = j;
                setBehaviorData
                
                if UI.settings.showBehavior
                    disp(['Testing behavior: ' UI.panel.behavior.files.String{UI.panel.behavior.files.Value}])
                    for i = 1:10
                        randomize_t0
                        plotData
                        
                        nextBehavior
                        plotData
                        
                        previousBehavior
                        plotData
                        
                        % Linearize
                        UI.panel.behavior.plotBehaviorLinearized.Value = 1;
                        plotBehaviorLinearized
                        plotData
                        UI.panel.behavior.plotBehaviorLinearized.Value = 0;
                        plotBehaviorLinearized
                        
                        % Below traces
                        UI.panel.behavior.showBehaviorBelowTrace.Value = 1;
                        showBehaviorBelowTrace
                        plotData
                        UI.panel.behavior.showBehaviorBelowTrace.Value = 0;
                        showBehaviorBelowTrace
                    end
                else
                    disp(['No behavior testing for: ' UI.panel.behavior.files.String{UI.panel.behavior.files.Value}])
                end
            end
            
            % Trials
            try
                UI.panel.behavior.showTrials.Value = 2;
            end
            showTrials
            if UI.settings.showTrials
                disp('Testing behavior trials')
                for i = 1:10
                    UI.panel.behavior.trialNumber.String = num2str(i);
                    gotoTrial
                    plotData
                    
                    nextTrial
                    plotData
                    previousTrial
                    plotData
                end
                disp('No behavior trials testing')
            end
            UI.panel.behavior.showBehavior.Value = 0;
            showBehavior
        end
        
        % % % % % % % % % % % % %
        % Other plots
        disp('Testing other plots')
        
        % Spectrogram
        UI.panel.spectrogram.showSpectrogram.Value = 1;
        UI.panel.spectrogram.spectrogramChannel.String = '1';
        UI.panel.spectrogram.spectrogramWindow.String = '0.2';
        UI.panel.spectrogram.freq_low.String = '10';
        UI.panel.spectrogram.freq_step_size.String = '5';
        UI.panel.spectrogram.freq_high.String = '100';
        
        toggleSpectrogram
        plotData
        
        UI.panel.spectrogram.showSpectrogram.Value = 0;
        UI.settings.spectrogram.show = false;
        
        % CSD
        UI.panel.csd.showCSD.Value = 1;
        show_CSD
        for j = 1:10
            randomize_t0
            plotData
        end
        UI.panel.csd.showCSD.Value = 0;
        UI.settings.CSD.show = false;
        
        % RMS Noise inset
        disp('Testing RMS inset')
        UI.panel.RMSnoiseInset.showRMSnoiseInset.Value = 1;
        toggleRMSnoiseInset
        for j = 1:10
            randomize_t0
            plotData
        end
        
        UI.panel.RMSnoiseInset.filter.Value = 1;
        toggleRMSnoiseInset
        plotData
        
        UI.panel.RMSnoiseInset.filter.Value = 2;
        toggleRMSnoiseInset 
        plotData
        
        UI.panel.RMSnoiseInset.filter.Value = 3;
        UI.panel.RMSnoiseInset.lowerBand.String = '100';
        UI.panel.RMSnoiseInset.higherBand.String = '200';
        toggleRMSnoiseInset
        for j = 1:10
            randomize_t0
            plotData
        end
        
        UI.panel.RMSnoiseInset.showRMSnoiseInset.Value = 0;
        
        % Instantaneous metrics
        disp('Testing instantaneous metrics')
        UI.panel.instantaneousMetrics.showPower.Value = 1;
        UI.panel.instantaneousMetrics.showSignal.Value = 1;
        UI.panel.instantaneousMetrics.showPhase.Value = 1;
        toggleInstantaneousMetrics
        for j = 1:10
            randomize_t0
            plotData
        end
        
        UI.panel.instantaneousMetrics.showPower.Value = 1;
        UI.panel.instantaneousMetrics.showSignal.Value = 1;
        UI.panel.instantaneousMetrics.showPhase.Value = 0;
        toggleInstantaneousMetrics
        for j = 1:10
            randomize_t0
            plotData
        end
        
        UI.panel.instantaneousMetrics.showPower.Value = 0;
        UI.panel.instantaneousMetrics.showSignal.Value = 1;
        UI.panel.instantaneousMetrics.showPhase.Value = 1;
        toggleInstantaneousMetrics
        for j = 1:10
            randomize_t0
            plotData
        end
        
        UI.panel.instantaneousMetrics.showPower.Value = 1;
        UI.panel.instantaneousMetrics.showSignal.Value = 0;
        UI.panel.instantaneousMetrics.showPhase.Value = 0;
        toggleInstantaneousMetrics
        for j = 1:10
            randomize_t0
            plotData
        end
        
        UI.panel.instantaneousMetrics.showPower.Value = 0;
        UI.panel.instantaneousMetrics.showSignal.Value = 0;
        UI.panel.instantaneousMetrics.showPhase.Value = 0;
        toggleInstantaneousMetrics
        
        % % % % % % % % % % % % %
        % Resetting settings
        UI.settings = settings_preTest;
        resetZoom
        initTraces        
        plotData
        
        TestSuite_toc = toc(TestSuite_tic);
        MsgLog(['Finished test suite (duration: ' num2str(TestSuite_toc,3),' seconds)'],2);
    end  
    
    function randomize_t0
    	UI.t0 = rand(1)*(UI.t_total-UI.settings.windowDuration);
    end
    
    
    function benchmarkChannelCount(showStats)
        % Stream from the end of the file, updating twice per window duration
        
        UI.settings.plotStyleDynamicRange = false;
        
        UI.settings.stream = true;
        UI.settings.fileRead = 'bof';
        benchmarkValues = zeros;
        
        channelOrder = [data.session.extracellular.electrodeGroups.channels{:}];
        UI.elements.lower.performance.String = 'Benchmarking...';
        
        for j_displays = 1:5
            if ~UI.settings.stream
                return
            end
            i_stream = 1;
            UI.settings.plotStyle = j_displays;
            while UI.settings.stream && i_stream*5<=numel(channelOrder)
                UI.settings.channelList = channelOrder(1:i_stream*5);
                initTraces                
                if ~ishandle(UI.fig)
                    return
                end
                if showStats
                    drawnow
                    nRuns = 10;
                else
                    nRuns = 1;
                end
                streamToc = zeros(1,nRuns);
                for i = 1:nRuns
                    UI.t0 = UI.t0+UI.settings.windowDuration;
                    UI.t0 = max([0,min([UI.t0,UI.t_total-UI.settings.windowDuration])]);
                    streamTic = tic;
                    UI.forceNewData = true;
                    plotData
                    if showStats
                        drawnow
                    end
                    streamToc(i) = toc(streamTic);
                end
                benchmarkValues(j_displays,i_stream) = mean(streamToc);
                i_stream = i_stream+1;
                UI.elements.lower.performance.String = ['Benchmarking ',num2str(i_stream*5),'/', num2str(numel(channelOrder))];
            end
        end
        
        if showStats
            fig_benchmark = figure('name','Summary figure','Position',[50 50 1200 900],'visible','off');
            gca1 = gca(fig_benchmark);
            plot(gca1,[1:size(benchmarkValues,2)]*5,benchmarkValues),
            title(gca1,'Benchmark of NeuroScope2'),
            xlabel(gca1,'Channels'),
            ylabel(gca1,'Plotting time (sec)')
            legend({'Downsampled','Range','Raw','LFP','Image'})
            
            movegui(fig_benchmark,'center'), set(fig_benchmark,'visible','on')
        end
        
        UI.buttons.play1.String = char(9654);
        UI.buttons.play2.String = [char(9655) char(9654)];
    end
    
    function benchmarkDuration(showStats)
        
        UI.settings.plotStyleDynamicRange = false;
        UI.settings.stream = true;
        UI.settings.fileRead = 'bof';
        benchmarkValues = zeros;
        UI.elements.lower.performance.String = 'Benchmarking...';
        durations = 0.3:0.1:2;
        
        for j_displays = 1:5
            if ~UI.settings.stream
                return
            end
            i_stream = 1;
            UI.settings.plotStyle = j_displays;
            initTraces
            UI.forceNewData = true;
            uiresume(UI.fig);
            while UI.settings.stream && i_stream<=numel(durations)
                UI.settings.windowDuration = durations(i_stream);
                UI.elements.lower.windowsSize.String = num2str(UI.settings.windowDuration);
                initTraces
                UI.forceNewData = true;
                resetZoom
                
                if ~ishandle(UI.fig)
                    return
                end
                if showStats
                    drawnow
                    nRuns = 10;
                else
                    nRuns = 1;
                end
                streamToc = zeros(1,nRuns);
                for i = 1:nRuns
                    UI.t0 = UI.t0+UI.settings.windowDuration;
                    UI.t0 = max([0,min([UI.t0,UI.t_total-UI.settings.windowDuration])]);
                    streamTic = tic;
                    UI.forceNewData = true;
                    plotData
                    if showStats
                        drawnow
                    end
                    streamToc(i) = toc(streamTic);
                end
                benchmarkValues(j_displays,i_stream) = mean(streamToc);
                i_stream = i_stream+1;
                UI.elements.lower.performance.String = ['Benchmarking ',num2str(i_stream),'/', num2str(numel(durations))];
            end
        end
        
        if showStats
            fig_benchmark = figure('name','Summary figure','Position',[50 50 1200 900],'visible','off');
            gca1 = gca(fig_benchmark);
            plot(gca1,durations,benchmarkValues),
            title(gca1,'Benchmark of windows duration in NeuroScope2'),
            xlabel(gca1,'Window duration (sec)'),
            ylabel(gca1,'Plotting time (sec)')
            legend({'Downsampled','Range','Raw','LFP','Image'})
            movegui(fig_benchmark,'center'), set(fig_benchmark,'visible','on')
        end
        
        UI.buttons.play1.String = char(9654);
        UI.buttons.play2.String = [char(9655) char(9654)];
    end
    
    function goToTimestamp(~,~)
        % Go to a specific timestamp via dialog
        UI.settings.stream = false;
        answer = inputdlg('Go go a specific timepoint (sec)','Navigate to timepoint', [1 50]);
        if ~isempty(answer)
            UI.t0 = valid_t0(str2num(answer{1}));
            resetZoom
            uiresume(UI.fig);
        end
    end

    function advance(step_size)
        if nargin==0
            step_size = 0.25;
        end
        % Advance the traces with step_size * window size
        UI.settings.stream = false;
        UI.t0 = UI.t0+step_size*UI.settings.windowDuration;
        uiresume(UI.fig);
    end

    function back(step_size)
        if nargin==0
            step_size = 0.25;
        end
        % Go back step_size * window size
        UI.t0 = max([UI.t0-step_size*UI.settings.windowDuration,0]);
        UI.settings.stream = false;
        uiresume(UI.fig);
    end

    function setTime(~,~)
        % Go to a specific timestamp
        UI.settings.stream = false;
        string1 = str2num(UI.elements.lower.time.String);
        if isnumeric(string1) & string1>=0
            UI.t0 = valid_t0(string1);
            resetZoom
            uiresume(UI.fig);
        end
    end

    function setWindowsSize(~,~)
        % Set the window size
        string1 = str2num(UI.elements.lower.windowsSize.String);
        string1 = string1(1);
        if isnumeric(string1) 
            if string1 < 0.001
                string1 = 1;
            elseif string1 > 100
                string1 = 100;
            elseif isnan(string1)
                string1 = 1;
            end
            UI.settings.windowDuration = round(string1*1000)/1000;
            UI.elements.lower.windowsSize.String = num2str(UI.settings.windowDuration);
            initTraces
            UI.forceNewData = true;
            resetZoom
            uiresume(UI.fig);
        end
    end

    function increaseWindowsSize(~,~)
        % Increase the window size
        windowSize_old = UI.settings.windowDuration;
        UI.settings.windowDuration = min([UI.settings.windowDuration*2,100]);
        UI.elements.lower.windowsSize.String = num2str(UI.settings.windowDuration);
        initTraces
        UI.forceNewData = true;
        uiresume(UI.fig);
    end

    function decreaseWindowsSize(~,~)
        % Decrease the window size
        windowSize_old = UI.settings.windowDuration;
        UI.settings.windowDuration = max([UI.settings.windowDuration/2,0.125]);
        UI.elements.lower.windowsSize.String = num2str(UI.settings.windowDuration);
        initTraces
        UI.forceNewData = true;
        uiresume(UI.fig);
    end

    function increaseAmplitude(~,~)
        % Decrease amplitude of the traces
        UI.settings.scalingFactor = min([UI.settings.scalingFactor*(sqrt(2)),100000]);
        setScalingText
        initTraces
        uiresume(UI.fig);
    end

    function decreaseAmplitude(~,~)
        % Increase amplitude of the ephys traces
        UI.settings.scalingFactor = max([UI.settings.scalingFactor/sqrt(2),1]);
        setScalingText
        initTraces
        uiresume(UI.fig);
    end

    function setScaling(~,~)
        string1 = str2num(UI.elements.lower.scaling.String);
        if ~isempty(string1) && isnumeric(string1) && string1>=1  && string1<100000
            UI.settings.scalingFactor = string1;
            setScalingText
            initTraces
            uiresume(UI.fig);
        end
    end
    
    function setScalingText
        UI.elements.lower.scalingText.String = ['Scaling (range: ',num2str(round(10000./UI.settings.scalingFactor)/10),char(181),'V) '];
    end

    function buttonsElectrodeGroups(src,~)
        % handles the three buttons under the electrode groups table
        switch src.String
            case 'None'
                if UI.uitabgroup_channels.Selection==1
                    UI.table.electrodeGroups.Data(:,1) = {false};
                    editElectrodeGroups
                elseif UI.uitabgroup_channels.Selection == 2
                    UI.listbox.channelList.Value = [];
                    buttonChannelList
                elseif UI.uitabgroup_channels.Selection == 3
                    UI.table.brainRegions.Data(:,1) = {false};
                    brainRegions = fieldnames(data.session.brainRegions);
                    UI.settings.brainRegionsToHide = brainRegions(~UI.table.brainRegions.Data{:,1});
                    initTraces;
                    uiresume(UI.fig);
                end
            case 'All'
                if UI.uitabgroup_channels.Selection==1
                    UI.table.electrodeGroups.Data(:,1) = {true};
                    editElectrodeGroups
                elseif UI.uitabgroup_channels.Selection == 2
                    UI.listbox.channelList.Value = 1:numel(UI.listbox.channelList.String);
                    buttonChannelList
                elseif UI.uitabgroup_channels.Selection == 3
                    UI.table.brainRegions.Data(:,1) = {true};
                    brainRegions = fieldnames(data.session.brainRegions);
                    UI.settings.brainRegionsToHide = brainRegions(~UI.table.brainRegions.Data{:,1});
                    initTraces;
                    uiresume(UI.fig);
                elseif UI.uitabgroup_channels.Selection == 4 && isfield(data.session.extracellular,'chanCoords') && ~isempty(data.session.extracellular.chanCoords.x) && ~isempty(data.session.extracellular.chanCoords.y)
                    image_toolbox_installed = isToolboxInstalled('Image Processing Toolbox');
                    if ~verLessThan('matlab', '9.5') & image_toolbox_installed
                        x_lim_data = [min(data.session.extracellular.chanCoords.x),max(data.session.extracellular.chanCoords.x)];
                        y_lim_data = [min(data.session.extracellular.chanCoords.y),max(data.session.extracellular.chanCoords.y)];
                        x_padding = 0.03*diff(x_lim_data);
                        y_padding = 0.03*diff(y_lim_data);
                        UI.plotpoints.roi_ChanCoords.Position = [x_lim_data(1)-x_padding,y_lim_data(1)-y_padding,1.06*diff(x_lim_data),1.06*diff(y_lim_data)];
                    end
                end
            otherwise
                data.session = gui_session(data.session,[],'extracellular');
                initData(basepath,basename);
                initTraces;
                uiresume(UI.fig);
        end
    end
    
    function getNotes(~,~)
        data.session.general.notes = UI.panel.notes.text.String;
    end
    
    function buttonsChannelTags(src,~)
        % handles the three buttons under the channel tags table
        switch src.String
            case 'New tag'
                if isempty(UI.selectedChannels)
                    selectedChannels = '';
                else
                    selectedChannels = num2str(UI.selectedChannels);
                end
                answer = inputdlg({'Tag name (e.g. Bad, Ripple, Theta)','Channels','Groups'},'Add channel tag', [1 50; 1 50; 1 50],{'',selectedChannels,''});
                if ~isempty(answer) && ~strcmp(answer{1},'') && isvarname(answer{1}) && (~isfield(data.session,'channelTags') || ~ismember(answer{1},fieldnames(data.session.channelTags)))
                    if ~isempty(answer{2}) && isnumeric(str2num(answer{2})) && all(str2num(answer{2})>0)
                        data.session.channelTags.(answer{1}).channels = str2num(answer{2});
                    end
                    if ~isempty(answer{3}) && isnumeric(str2num(answer{3})) && all(str2num(answer{3})>0)
                        data.session.channelTags.(answer{1}).electrodeGroups = str2num(answer{3});
                    end
                    updateChannelTags
                    uiresume(UI.fig);
                end
            case 'Delete tag(s)'
                if isfield(data.session,'channelTags') && ~isempty(fieldnames(data.session.channelTags))
                    list = fieldnames(data.session.channelTags);
                    [indx,tf] = listdlg('ListString',list,'name','Delete tag(s)','PromptString','Select tag(s) to delete');
                    if ~isempty(indx)
                        data.session.channelTags = rmfield(data.session.channelTags,list(indx));
                        updateChannelTags
                        UI.settings.channelTags.hide = [];
                        UI.settings.channelTags.filter = [];
                        UI.settings.channelTags.highlight = [];
                        initTraces
                        uiresume(UI.fig);
                    end
                end
            otherwise % 'Save'
                saveSessionMetadata
        end
    end

    function saveSessionMetadata(~,~)
        session = data.session;
        session.neuroScope2.t0 = UI.t0;
        saveStruct(session);
        MsgLog('Session metadata saved',2);
    end
    
    function toggleSpikes(~,~)
        % Toggle spikes data
        if ~isfield(data,'spikes') && exist(fullfile(basepath,[basename,'.spikes.cellinfo.mat']),'file')
            data.spikes = loadSpikes('session',data.session);
            data.spikes.spindices = generateSpinDices(data.spikes.times);
            if ~isfield(data.spikes,'maxWaveformCh1') && isfield(data.spikes,'maxWaveformCh')
                data.spikes.maxWaveformCh1 = data.spikes.maxWaveformCh+1;
            elseif ~isfield(data.spikes,'maxWaveformCh1')
                for i = 1:data.spikes.numcells
                    data.spikes.maxWaveformCh1(i) = data.session.extracellular.electrodeGroups.channels{data.spikes.shankID(i)}(1);
                end
            end
        elseif ~exist(fullfile(basepath,[basename,'.spikes.cellinfo.mat']),'file')
            UI.panel.spikes.showSpikes.Value = 0;
            MsgLog('Spikes does not exist',4);
            return
        end
        UI.settings.showSpikes = ~UI.settings.showSpikes;
        if UI.settings.showSpikes
            UI.panel.spikes.showSpikes.Value = 1;
            
            spikes_fields = fieldnames(data.spikes);
            subfieldstypes = struct2cell(structfun(@class,data.spikes,'UniformOutput',false));
            subfieldssizes = struct2cell(structfun(@size,data.spikes,'UniformOutput',false));
            subfieldssizes = cell2mat(subfieldssizes);
            idx = ismember(subfieldstypes,{'double','cell'}) & all(subfieldssizes == [1,data.spikes.numcells],2);
            spikes_fields = spikes_fields(idx);
            UI.settings.spikesYDataType = subfieldstypes(idx);
            excluded_fields = {'times','ts','ts_eeg','maxWaveform_all','channels_all','peakVoltage_sorted','timeWaveform','amplitudes','ids'};
            [spikes_fields,ia] = setdiff(spikes_fields,excluded_fields);
            UI.settings.spikesYDataType = UI.settings.spikesYDataType(ia);

            idx_toKeep = [];
            for i = 1:numel(spikes_fields)
                if strcmp(UI.settings.spikesYDataType{i},'cell')
                    if all(all([cellfun(@(X) size(X,1), data.spikes.(spikes_fields{i}));cellfun(@(X) size(X,2), data.spikes.(spikes_fields{i}))] == [data.spikes.total;ones(1,data.spikes.numcells)])) || all(all([cellfun(@(X) size(X,1), data.spikes.(spikes_fields{i}));cellfun(@(X) size(X,2), data.spikes.(spikes_fields{i}))] == [ones(1,data.spikes.numcells);data.spikes.total]))
                        idx_toKeep = [idx_toKeep,i];
                    end
                elseif strcmp(UI.settings.spikesYDataType{i},'double')
                    idx_toKeep = [idx_toKeep,i];
                end
            end
            UI.settings.spikesYDataType = UI.settings.spikesYDataType(idx_toKeep);
            YDataList = spikes_fields(idx_toKeep);
            YDataList(strcmp(YDataList,'UID')) = [];
            if UI.settings.useMetrics
                YDataList = ['Cell metrics';YDataList];
            else
                YDataList = ['UID';YDataList];
            end
            UI.panel.spikes.setSpikesYData.String = YDataList;
            
            if isempty(UI.panel.spikes.setSpikesYData.Value)
                UI.panel.spikes.setSpikesYData.Value = 1;
            end
            UI.params.subsetTable = 1:data.spikes.numcells;
            UI.params.subsetFilter = 1:data.spikes.numcells;
            UI.params.subsetGroups = 1:data.spikes.numcells;
            UI.params.subsetCellType = 1:data.spikes.numcells;
            
            UI.panel.spikes.setSpikesGroupColors.Enable = 'on';
            if UI.panel.spikes.showSpikesBelowTrace.Value == 1
                UI.panel.spikes.setSpikesYData.Enable = 'on';
            else
                UI.panel.spikes.setSpikesYData.Enable = 'off';
            end
        else
            UI.panel.spikes.showSpikes.Value = 0;
            UI.panel.spikes.setSpikesYData.Enable = 'off';
            UI.panel.spikes.setSpikesGroupColors.Enable = 'off';
            spikes_fields = {''};
        end
        initTraces
        uiresume(UI.fig);
    end

    function toggleMetrics(~,~)
        % Toggle cell metrics data
        if ~isfield(data,'cell_metrics') && exist(fullfile(basepath,[basename,'.cell_metrics.cellinfo.mat']),'file')
            data.cell_metrics = loadCellMetrics('session',data.session);
            
            % Initialize labels
            if ~isfield(data.cell_metrics, 'labels')
                data.cell_metrics.labels = repmat({''},1,data.cell_metrics.general.cellCount);
            end
            % Initialize labels
            if ~isfield(data.cell_metrics, 'synapticEffect')
                data.cell_metrics.synapticEffect = repmat({'Unknown'},1,data.cell_metrics.general.cellCount);
            end
            
            % Initialize groups
            if ~isfield(data.cell_metrics, 'groups')
                data.cell_metrics.groups = struct();
            end

        elseif ~exist(fullfile(basepath,[basename,'.cell_metrics.cellinfo.mat']),'file')
            UI.panel.cell_metrics.useMetrics.Value = 0;
            MsgLog('Cell_metrics does not exist',4);
            return
        end
        UI.settings.useMetrics = ~UI.settings.useMetrics;
        if UI.settings.useMetrics
            UI.panel.cell_metrics.useMetrics.Value = 1;
            spikes_fields = fieldnames(data.cell_metrics);
            subfieldstypes = struct2cell(structfun(@class,data.cell_metrics,'UniformOutput',false));
            subfieldssizes = struct2cell(structfun(@size,data.cell_metrics,'UniformOutput',false));
            subfieldssizes = cell2mat(subfieldssizes);
            
            % Sorting
            idx = ismember(subfieldstypes,{'double','cell'}) & all(subfieldssizes == [1,data.cell_metrics.general.cellCount],2);
            spikes_fields1 = spikes_fields(idx);
            UI.panel.cell_metrics.sortingMetric.String = spikes_fields1;
            UI.panel.cell_metrics.sortingMetric.Value = find(strcmp(spikes_fields1,UI.params.sortingMetric));
            if isempty(UI.panel.cell_metrics.sortingMetric.Value)
                UI.panel.cell_metrics.sortingMetric.Value = 1;
            end
            if UI.settings.spikesBelowTrace
                UI.panel.cell_metrics.sortingMetric.Enable = 'on';
            end
            UI.panel.spikes.setSpikesYData.String{1} = 'Cell metrics';
            
            % Grouping
            idx = ismember(subfieldstypes,{'cell'}) & all(subfieldssizes == [1,data.cell_metrics.general.cellCount],2);
            spikes_fields2 = spikes_fields(idx);
            UI.panel.cell_metrics.groupMetric.String = spikes_fields2;
            UI.panel.cell_metrics.groupMetric.Value = find(strcmp(spikes_fields2,UI.params.groupMetric));
            if isempty(UI.panel.cell_metrics.groupMetric.Value)
                UI.panel.cell_metrics.groupMetric.Value = 1;
            end
            UI.panel.cell_metrics.groupMetric.Enable = 'on';
            UI.panel.cell_metrics.textFilter.Enable = 'on';
            UI.panel.cell_metrics.defineGroupData.Enable = 'on';
            UI.params.subsetTable = 1:data.cell_metrics.general.cellCount;
            initCellsTable
            
            % Cell type list
            UI.listbox.cellTypes.Enable = 'on';
            [UI.params.cellTypes,~,clusClas] = unique(data.cell_metrics.putativeCellType);
            UI.params.cell_class_count = histc(clusClas,1:length(UI.params.cellTypes));
            UI.params.cell_class_count = cellstr(num2str(UI.params.cell_class_count))';
            UI.listbox.cellTypes.String = strcat(UI.params.cellTypes,' (',UI.params.cell_class_count,')');
            UI.listbox.cellTypes.Value = 1:length(UI.params.cellTypes);
            UI.params.subsetCellType = 1:data.cell_metrics.general.cellCount;
            
            UI.panel.spikes.setSpikesGroupColors.String = {'UID','Single color','Electrode groups','Cell metrics'};
            UI.panel.spikes.setSpikesGroupColors.Value = 4; 
            UI.settings.spikesGroupColors = 4;
        else
            UI.panel.cell_metrics.useMetrics.Value = 0;
            UI.panel.cell_metrics.sortingMetric.Enable = 'off';
            UI.panel.cell_metrics.groupMetric.Enable = 'off';
            UI.panel.cell_metrics.textFilter.Enable = 'off';
            UI.panel.cell_metrics.defineGroupData.Enable = 'off';
            UI.listbox.cellTypes.Enable = 'off';
            spikes_fields = {''};
            UI.table.cells.Data = {''};
            UI.table.cells.Enable = 'off';
            if UI.panel.spikes.setSpikesGroupColors.Value == 4
                UI.panel.spikes.setSpikesGroupColors.Value = 1;
                UI.settings.spikesGroupColors = 1;
            end
            UI.panel.spikes.setSpikesGroupColors.String = {'UID','Single color','Electrode groups'};
            UI.panel.spikes.setSpikesYData.String{1} = 'UID';
        end
        uiresume(UI.fig);
    end
    
    function toggleSpectrogram(~,~)
        numeric_gt_0 = @(n) ~isempty(n) && isnumeric(n) && (n > 0); % numeric and greater than 0
        numeric_gt_oe_0 = @(n) ~isempty(n) && isnumeric(n) && (n >= 0); % Numeric and greater than or equal to 0
        
        if UI.panel.spectrogram.showSpectrogram.Value == 1
            % Channel to use
            channelnumber = str2num(UI.panel.spectrogram.spectrogramChannel.String);
            if isnumeric(channelnumber) && channelnumber>0 && channelnumber<=data.session.extracellular.nChannels
                UI.settings.spectrogram.channel = channelnumber;
                UI.settings.spectrogram.show = true;
            else
                UI.settings.spectrogram.show = false;
                MsgLog('The spectrogram channel is not valid',4);
                return
            end
            
            % Window width
            window1 = str2num(UI.panel.spectrogram.spectrogramWindow.String);
            if numeric_gt_0(window1) && window1<UI.settings.windowDuration
                UI.settings.spectrogram.window = window1;
                UI.settings.spectrogram.show = true;
            else
                UI.settings.spectrogram.show = false;
                MsgLog('The spectrogram window width is not valid',4);
                return
            end
            
            % Frequency range and step size
            freq_low = str2num(UI.panel.spectrogram.freq_low.String);
            freq_step_size = str2num(UI.panel.spectrogram.freq_step_size.String);
            freq_high = str2num(UI.panel.spectrogram.freq_high.String);
            freq_range = [freq_low : freq_step_size : freq_high];
            
            if numeric_gt_oe_0(freq_low) && numeric_gt_0(freq_step_size) && numeric_gt_0(freq_high) && freq_high > freq_low && numel(freq_range)>1
                UI.settings.spectrogram.freq_low = freq_low;
                UI.settings.spectrogram.freq_step_size = freq_step_size;
                UI.settings.spectrogram.freq_high = freq_high;
                UI.settings.spectrogram.freq_range = freq_range;
                UI.settings.spectrogram.show = true;
                
                % Determining the optioal y-ticks
                n_min_ticks = 10;
                y_tick_step_options = [0.1,1,2,5,10,20,50,100,200,500];
                
                axis_ticks_optimal = (freq_range(end)-freq_range(1))/n_min_ticks; 
                y_tick_step = interp1(y_tick_step_options,y_tick_step_options,axis_ticks_optimal,'nearest');
                 
                y_ticks = [y_tick_step*ceil(freq_range(1)/y_tick_step):y_tick_step:y_tick_step*floor(freq_range(end)/y_tick_step)];
                UI.settings.spectrogram.y_ticks = y_ticks;
            else
                UI.settings.spectrogram.show = false;
                UI.panel.spectrogram.showSpectrogram.Value = 0;
                MsgLog('The spectrogram frequency range is not valid',4);
            end
        else
            UI.settings.spectrogram.show = false;
        end
        initTraces
        uiresume(UI.fig);
    end

    function setSortingMetric(~,~)
        UI.params.sortingMetric = UI.panel.cell_metrics.sortingMetric.String{UI.panel.cell_metrics.sortingMetric.Value};
        uiresume(UI.fig);
    end

    function setCellTypeSelectSubset(~,~)
        UI.params.subsetCellType = find(ismember(data.cell_metrics.putativeCellType,UI.params.cellTypes(UI.listbox.cellTypes.Value)));
        uiresume(UI.fig);
    end

    function setGroupMetric(~,~)
        UI.params.groupMetric = UI.panel.cell_metrics.groupMetric.String{UI.panel.cell_metrics.groupMetric.Value};
        uiresume(UI.fig);
    end

    function initCellsTable(~,~)
        dataTable = {};
        column1 = data.cell_metrics.(UI.tableData.Column1)';
        column2 = data.cell_metrics.(UI.tableData.Column2)';
        if isnumeric(column1)
            column1 = num2cell(column1);
        end
        if isnumeric(column2)
            column2 = num2cell(column2);
        end
        dataTable(:,2) = cellstr(num2str(UI.params.subsetTable'));
        dataTable(:,3) = column1;
        dataTable(:,4) = column2;
        dataTable(:,1) = {false};
        dataTable(UI.params.subsetTable,1) = {true};
        UI.table.cells.Data = dataTable;
        UI.table.cells.Enable = 'on';
    end

    function editCellTable(~,~)
        UI.params.subsetTable = find([UI.table.cells.Data{:,1}]);
    end

    function metricsButtons(src,~)
        switch src.String
            case 'None'
                UI.table.cells.Data(:,1) = {false};
                UI.params.subsetTable = find([UI.table.cells.Data{:,1}]);
                uiresume(UI.fig);
            case 'All'
                UI.table.cells.Data(:,1) = {true};
                UI.params.subsetTable = find([UI.table.cells.Data{:,1}]);
                uiresume(UI.fig);
            case 'Metrics'
                if isfield(data,'cell_metrics')
                    if ~isempty(UI.selectedUnits)
                        generate_cell_metrics_table(data.cell_metrics, UI.selectedUnits);
                    else
                        generate_cell_metrics_table(data.cell_metrics);
                    end
                end
        end
    end

    function filterCellsByText(~,~)
        if isnumeric(str2num(UI.panel.cell_metrics.textFilter.String)) && ~isempty(UI.panel.cell_metrics.textFilter.String) && ~isempty(str2num(UI.panel.cell_metrics.textFilter.String))
                UI.params.subsetFilter = str2num(UI.panel.cell_metrics.textFilter.String);
        elseif ~isempty(UI.panel.cell_metrics.textFilter.String) && ~strcmp(UI.panel.cell_metrics.textFilter.String,'Filter')
            if isempty(UI.freeText)
                UI.freeText = {''};
                fieldsMenuCells = fieldnames(data.cell_metrics);
                fieldsMenuCells = fieldsMenuCells(strcmp(struct2cell(structfun(@class, data.cell_metrics, 'UniformOutput', false)), 'cell'));
                for j = 1:length(fieldsMenuCells)
                    UI.freeText = strcat(UI.freeText, {' '}, data.cell_metrics.(fieldsMenuCells{j}));
                end
                UI.params.alteredCellMetrics = 0;
            end
            
            [newStr2,matches] = split(UI.panel.cell_metrics.textFilter.String,[" & "," | "," OR "," AND "]);
            idx_textFilter2 = zeros(length(newStr2),data.cell_metrics.general.cellCount);
            failCheck = 0;
            for i = 1:length(newStr2)
                if numel(newStr2{i})>11 && strcmp(newStr2{i}(1:12),'.brainRegion')
                    newStr = split(newStr2{i}(2:end),' ');
                    if numel(newStr)>1
                        if isempty(UI.brainRegions.relational_tree)
                            load('brainRegions_relational_tree.mat','relational_tree');
                        end
                        acronym_out = getBrainRegionChildren(newStr{2},UI.brainRegions.relational_tree);
                        idx_textFilter2(i,:) = ismember(lower(data.cell_metrics.brainRegion),lower([acronym_out,newStr{2}]));
                    end
                elseif strcmp(newStr2{i}(1),'.')
                    newStr = split(newStr2{i}(2:end),' ');
                    if length(newStr)==3 && isfield(data.cell_metrics,newStr{1}) && isnumeric(data.cell_metrics.(newStr{1})) && contains(newStr{2},{'==','>','<','~='})
                        switch newStr{2}
                            case '>'
                                idx_textFilter2(i,:) = data.cell_metrics.(newStr{1}) > str2num(newStr{3});
                            case '<'
                                idx_textFilter2(i,:) = data.cell_metrics.(newStr{1}) < str2num(newStr{3});
                            case '=='
                                idx_textFilter2(i,:) = data.cell_metrics.(newStr{1}) == str2num(newStr{3});
                            case '~='
                                idx_textFilter2(i,:) = data.cell_metrics.(newStr{1}) ~= str2num(newStr{3});
                            otherwise
                                failCheck = 1;
                        end
                    elseif length(newStr)==3 && ~isfield(data.cell_metrics,newStr{1}) && contains(newStr{2},{'==','>','<','~='})
                        failCheck = 2;
                    else
                        failCheck = 1;
                    end
                else
                    idx_textFilter2(i,:) = contains(UI.freeText,newStr2{i},'IgnoreCase',true);
                end
            end
            if failCheck == 0
                orPairs = find(contains(matches,{' | ',' OR '}));
                if ~isempty(orPairs)
                    for i = 1:length(orPairs)
                        idx_textFilter2([orPairs(i),orPairs(i)+1],:) = any(idx_textFilter2([orPairs(i),orPairs(i)+1],:)).*[1;1];
                    end
                end
                UI.params.subsetFilter = find(all(idx_textFilter2,1));
                MsgLog([num2str(length(UI.params.subsetFilter)),'/',num2str(data.cell_metrics.general.cellCount),' cells selected with ',num2str(length(newStr2)),' filter: ' ,UI.panel.cell_metrics.textFilter.String]);
            elseif failCheck == 2
                MsgLog('Filter not formatted correctly. Field does not exist',2);
            else
                MsgLog('Filter not formatted correctly',2);
                UI.params.subsetFilter = 1:data.cell_metrics.general.cellCount;
            end
        else
            UI.params.subsetFilter = 1:data.cell_metrics.general.cellCount;
            MsgLog('Filter reset');
        end
        if isempty(UI.params.subsetFilter)
            UI.params.subsetFilter = 1:data.cell_metrics.general.cellCount;
        end
        uiresume(UI.fig);
    end

    function reverseSpikeSorting(~,~)
        if UI.panel.spikes.reverseSpikeSorting.Value == 1
            UI.settings.reverseSpikeSorting = 'descend';
        else
            UI.settings.reverseSpikeSorting = 'ascend';
        end
        setSpikesYData
        uiresume(UI.fig);
    end

    function showSpikesBelowTrace(~,~)
        if UI.panel.spikes.showSpikesBelowTrace.Value == 1
            UI.settings.spikesBelowTrace = true;
            if UI.settings.showSpikes
                UI.panel.spikes.setSpikesYData.Enable = 'on';
            end
            if UI.settings.useMetrics
                UI.panel.cell_metrics.sortingMetric.Enable = 'on';
            end
        else
            UI.settings.spikesBelowTrace = false;
            UI.panel.spikes.setSpikesYData.Enable = 'off';
            UI.panel.cell_metrics.sortingMetric.Enable = 'off';
        end
        initTraces
        uiresume(UI.fig);
    end    
    
    function setSpikesGroupColors(~,~)
        UI.settings.spikesGroupColors = UI.panel.spikes.setSpikesGroupColors.Value;
        uiresume(UI.fig);
    end
    
    function setSpikesYData(~,~)
        UI.settings.spikesYData = UI.panel.spikes.setSpikesYData.String{UI.panel.spikes.setSpikesYData.Value};
        groups = [];
        [~,sortidx] = sort(cat(1,data.spikes.times{:})); % Sorting spikes
        if UI.panel.spikes.setSpikesYData.Value > 1
            if numel(data.spikes.times)>0
                switch UI.settings.spikesYDataType{UI.panel.spikes.setSpikesYData.Value}
                    case 'double'
                        if length(data.spikes.(UI.settings.spikesYData)) == data.spikes.numcells
                            [~,order1] = sort(data.spikes.(UI.settings.spikesYData),UI.settings.reverseSpikeSorting);
                            [~,order2] = sort(order1);
                            for i = 1:numel(data.spikes.(UI.settings.spikesYData))
                                groups = [groups,order2(i)*ones(1,data.spikes.total(i))]; % from cell to array
                            end
                            data.spikes.spindices(:,3) = groups(sortidx); % Combining spikes and sorted group ids
                            UI.settings.useSpikesYData = true;
                        else
                            UI.settings.useSpikesYData = false;
                            UI.panel.spikes.setSpikesYData.Value = 1;
                        end
                    case 'cell'
                        try
                            if size(data.spikes.(UI.settings.spikesYData){1},2)==1
                                for i = 1:numel(data.spikes.(UI.settings.spikesYData))
                                    groups = [groups,data.spikes.(UI.settings.spikesYData){i}']; % from cell to array
                                end
                            elseif size(data.spikes.(UI.settings.spikesYData){1},1)==1
                                for i = 1:numel(data.spikes.(UI.settings.spikesYData))
                                    groups = [groups,data.spikes.(UI.settings.spikesYData){i}]; % from cell to array
                                end
                            end
                        catch
                            UI.settings.useSpikesYData = false;
                            UI.panel.spikes.setSpikesYData.Value = 1;
                            warning('Failed to set sorting')
                        end
                        data.spikes.spindices(:,3) = groups(sortidx); % Combining spikes and sorted group ids
                        if contains(UI.settings.spikesYData,'phase')
                            idx = (data.spikes.spindices(:,3) < 0);
                            data.spikes.spindices(idx,3) = data.spikes.spindices(idx,3)+2*pi;
                        end
                end
            end
            % Getting limits
            UI.settings.spikes_ylim = [min(data.spikes.spindices(:,3)),max(data.spikes.spindices(:,3))];
        else
            UI.settings.useSpikesYData = false;
        end
        % initTraces
        uiresume(UI.fig);
    end
        
    function showSpikeWaveforms(~,~)
        numeric_gt_0 = @(n) ~isempty(n) && isnumeric(n) && (n > 0) && (n <= 1); % numeric and greater than 0 and less or equal than 1
        if UI.panel.spikes.showSpikeWaveforms.Value == 1 && isfield(data.session.extracellular,'chanCoords')
            UI.settings.showSpikeWaveforms = true;
        elseif UI.panel.spikes.showSpikeWaveforms.Value == 1
            UI.settings.showSpikeWaveforms = false;
            UI.panel.spikes.showSpikeWaveforms.Value = 0;
            MsgLog('ChanCoords have not been defined for this session','4')
        else
            UI.settings.showSpikeWaveforms = false;
        end
        if numeric_gt_0(str2num(UI.panel.spikes.waveformsRelativeWidth.String))
            UI.settings.waveformsRelativeWidth = str2num(UI.panel.spikes.waveformsRelativeWidth.String);
        end
        initTraces
        uiresume(UI.fig);
    end
    
    function showSpikesPCAspace(~,~)
        numeric_gt_0 = @(n) ~isempty(n) && isnumeric(n) && (n > 0) && (n <= data.session.extracellular.nElectrodeGroups); % numeric and greater than 0 and less or equal than nElectrodes
        if UI.panel.spikes.showSpikesPCAspace.Value == 1
            UI.settings.showSpikesPCAspace = true;
        else
            UI.settings.showSpikesPCAspace = false;
        end
        PCA_electrodeGroup = str2num(UI.panel.spikes.PCA_electrodeGroup.String);
        if numeric_gt_0(PCA_electrodeGroup)
            UI.settings.PCAspace_electrodeGroup = ceil(PCA_electrodeGroup);
            UI.panel.spikes.PCA_electrodeGroup.String = num2str(UI.settings.PCAspace_electrodeGroup);
        else
            UI.settings.showSpikesPCAspace = false;
            UI.panel.spikes.showSpikesPCAspace.Value = 0;
            MsgLog('The electrode group for the PCA space is not valid',4)
        end        
        initTraces
        uiresume(UI.fig);
    end
        
    function showSpikeMatrix(~,~)
        if UI.panel.spikes.showSpikeMatrix.Value == 1
            UI.settings.showSpikeMatrix = true;
        else
            UI.settings.showSpikeMatrix = false;
        end
        uiresume(UI.fig);
    end

    function initTraces
        set(UI.fig,'Renderer','opengl');
        % Determining data offsets
        UI.offsets.intan    = 0.10 * (UI.settings.showTimeseriesBelowTrace & (UI.settings.intan_showAnalog | UI.settings.intan_showAux | UI.settings.intan_showDigital));
        UI.offsets.trials   = 0.02 * (UI.settings.showTrials);
        UI.offsets.behavior = 0.08 * (UI.settings.showBehaviorBelowTrace && UI.settings.plotBehaviorLinearized && UI.settings.showBehavior);
        UI.offsets.states   = 0.04 * (UI.settings.showStates);
        UI.offsets.spectrogram = 0.25 * (UI.settings.spectrogram.show);
        UI.offsets.instantaneousMetrics = 0.20 * (UI.settings.instantaneousMetrics.show);
        UI.offsets.processing = 0.04 * (UI.settings.processing_steps && any(UI.settings.showEvents));
        UI.offsets.events   = 0.04 * any(UI.settings.showEventsBelowTrace & UI.settings.showEvents);
        UI.offsets.kilosort = 0.08 * (UI.settings.showKilosort && UI.settings.kilosortBelowTrace);
        UI.offsets.klusta = 0.08 * (UI.settings.showKlusta && UI.settings.klustaBelowTrace);
        UI.offsets.spykingcircus = 0.08 * (UI.settings.showSpykingcircus && UI.settings.spykingcircusBelowTrace);
        UI.offsets.spikes   = 0.08 * (UI.settings.spikesBelowTrace && UI.settings.showSpikes);
        UI.offsets.populationRate = 0.08 * ((UI.settings.detectSpikes && UI.settings.showDetectedSpikesPopulationRate) || (UI.settings.showSpikes && UI.settings.showPopulationRate));
        UI.offsets.detectedSpikes = 0.08 * (UI.settings.detectSpikes && UI.settings.detectedSpikesBelowTrace);
        UI.offsets.detectedEvents = 0.08 * (UI.settings.detectEvents && UI.settings.detectedEventsBelowTrace);
        UI.offsets.spikeWaveforms = 0.25 * (UI.settings.showWaveformsBelowTrace && ( (UI.settings.showSpikeWaveforms && UI.settings.showSpikes) || (UI.settings.showDetectedSpikeWaveforms && UI.settings.detectSpikes) ) ); 
        
        offset_all = 0;
        padding = 0.005;
        
        list = fieldnames(UI.offsets);
        for i = 1:numel(list)
            if UI.offsets.(list{i}) > 0
                offset_all = offset_all + UI.offsets.(list{i}) + padding;
            end
        end
        if UI.settings.plotStyle == 6 && offset_all>0
            ui_scaling = 1/(offset_all + padding);
        else
            ui_scaling = 1;
        end

        offset = 0;
        
        for i = 1:numel(list)
            if UI.offsets.(list{i}) == 0
                UI.dataRange.(list{i}) = [0,1];
            else
                UI.dataRange.(list{i}) = [0,UI.offsets.(list{i}) * ui_scaling] + offset;
                offset = offset + UI.offsets.(list{i}) * ui_scaling + padding;
            end
        end
        UI.dataRange.ephys = [offset+UI.settings.ephys_padding,1-UI.settings.ephys_padding+offset*UI.settings.ephys_padding];
        % Initialize the trace data with current metadata and configuration
        UI.channels = data.session.extracellular.electrodeGroups.channels;
        if isfield(data.session,'channelTags')
            UI.channelTags = fieldnames(data.session.channelTags);
        end
        if ~isempty(UI.settings.channelTags.hide) && isfield(data.session,'channelTags')
            for j = 1:numel(UI.channels)
                for i = 1:numel(UI.settings.channelTags.hide)
                    if isfield(data.session.channelTags.(UI.channelTags{UI.settings.channelTags.hide(i)}),'channels') && ~isempty(data.session.channelTags.(UI.channelTags{UI.settings.channelTags.hide(i)}).channels)
                        UI.channels{j}(ismember(UI.channels{j},data.session.channelTags.(UI.channelTags{UI.settings.channelTags.hide(i)}).channels)) = [];
                    end
                end
            end
        end
        if ~isempty(UI.settings.channelTags.filter) && isfield(data.session,'channelTags')
            for j = 1:numel(UI.channels)
                for i = 1:numel(UI.settings.channelTags.filter)
                    if isfield(data.session.channelTags.(UI.channelTags{UI.settings.channelTags.filter(i)}),'channels') && ~isempty(data.session.channelTags.(UI.channelTags{UI.settings.channelTags.filter(i)}).channels)
                        [~,idx] = setdiff(UI.channels{j},data.session.channelTags.(UI.channelTags{UI.settings.channelTags.filter(i)}).channels);
                        UI.channels{j}(idx) = [];
                    end
                end
            end
        end
        
        % Filtering channel by channel list
        for j = 1:numel(UI.channels)
            [~,idx] = setdiff(UI.channels{j},UI.settings.channelList);
            UI.channels{j}(idx) = [];
        end
        
        % Filtering channels by brain region list
        for j = 1:numel(UI.channels)
            for k = 1:numel(UI.settings.brainRegionsToHide)
                channels = data.session.brainRegions.(UI.settings.brainRegionsToHide{k}).channels;
                UI.channels{j}(ismember(UI.channels{j},channels)) = [];
            end
        end
        
        % Filtering channels by channel coordinates
        for j = 1:numel(UI.channels)
            [~,idx] = setdiff(UI.channels{j},UI.settings.chanCoordsToPlot);
            UI.channels{j}(idx) = [];
        end
        
        channels = [UI.channels{UI.settings.electrodeGroupsToPlot}];
        
        if UI.settings.channelOrder == 1
            UI.channelOrder = [UI.channels{UI.settings.electrodeGroupsToPlot}];
        elseif UI.settings.channelOrder == 2
            UI.channelOrder = flip([UI.channels{UI.settings.electrodeGroupsToPlot}]);
        elseif UI.settings.channelOrder == 3
            UI.channelOrder = sort([UI.channels{UI.settings.electrodeGroupsToPlot}],'ascend');
        elseif UI.settings.channelOrder == 4
            UI.channelOrder = sort([UI.channels{UI.settings.electrodeGroupsToPlot}],'descend');
        end
        
        nChannelsToPlot = numel(UI.channelOrder);
        UI.channelMap = zeros(1,data.session.extracellular.nChannels);
        [idx, idx2]= ismember([data.session.extracellular.electrodeGroups.channels{:}],channels);
        [~,temp] = sort([data.session.extracellular.electrodeGroups.channels{:}]);
        channels_1 = [data.session.extracellular.electrodeGroups.channels{:}];
        UI.channelMap(channels_1(find(idx))) = channels(idx2(idx2~=0));
        padding = UI.settings.ephys_padding + 0.5./numel(UI.channelOrder);
        
        UI.settings.channels_relative_offset = zeros(1,data.session.extracellular.nChannels);
        
        if UI.settings.plotTracesInColumns
            if UI.settings.showChannelNumbers
                electrodegroup_spacing = 0.13;
            else
               	electrodegroup_spacing = 0.03;
            end
            UI.settings.columns = numel(UI.settings.electrodeGroupsToPlot)+numel(UI.settings.electrodeGroupsToPlot)*electrodegroup_spacing;
            for i = 1:length(UI.settings.electrodeGroupsToPlot)
                UI.settings.channels_relative_offset(UI.channels{UI.settings.electrodeGroupsToPlot(i)})=((i-1)/numel(UI.settings.electrodeGroupsToPlot))*UI.settings.windowDuration+UI.settings.windowDuration*electrodegroup_spacing/2/numel(UI.settings.electrodeGroupsToPlot);
            end
        else
            UI.settings.columns = 1;
        end
        
        if nChannelsToPlot == 1
        	channelOffset = 0.5;
        elseif nChannelsToPlot == 0
            channelOffset = [];
        elseif UI.settings.plotTracesInColumns
            nChannelsInGroups = cellfun(@numel,UI.channels(UI.settings.electrodeGroupsToPlot));
            nChannelsInGroups_cumsum = [0,cumsum(nChannelsInGroups)];
            vertical_Offset = [0:max(nChannelsInGroups)-1]/(max(nChannelsInGroups)-1)*(1-2*padding)*(1-offset)+padding*(1-offset);
            channelOffset = zeros(1,nChannelsToPlot);
            for i = 1:numel(UI.settings.electrodeGroupsToPlot)
                channels = (1:nChannelsInGroups(i))+nChannelsInGroups_cumsum(i);
                channelOffset(channels) = vertical_Offset(1:nChannelsInGroups(i));
            end
            UI.settings.columns_height = (vertical_Offset(2)-vertical_Offset(1))*0.8;
        elseif UI.settings.extraSpacing && ~isempty(UI.settings.electrodeGroupsToPlot) && UI.settings.plotStyle < 5
            nChannelsInGroups = cellfun(@numel,UI.channels(UI.settings.electrodeGroupsToPlot));
            channelList = [];
            for i = 1:numel(UI.settings.electrodeGroupsToPlot)
                if ~isempty(nChannelsInGroups(i))
                    channelList = [channelList,(0:nChannelsInGroups(i)-1)+numel(channelList)+sum(nChannelsInGroups(1:i)>0)*1.5];
                end
            end
            channelOffset = (channelList-1)/(channelList(end)-1)*(1-2*padding)*(1-offset)+padding*(1-offset);
        else
            channelOffset = [0:nChannelsToPlot-1]/(nChannelsToPlot-1)*(1-2*padding)*(1-offset)+padding*(1-offset);
        end
        UI.channelOffset = zeros(1,data.session.extracellular.nChannels);
        UI.channelOffset(UI.channelOrder) = channelOffset-1;
        UI.ephys_offset = offset;
        if UI.settings.plotStyle == 4
            UI.channelScaling = ones(ceil(UI.settings.windowDuration*data.session.extracellular.srLfp),1)*UI.channelOffset;
            UI.samplesToDisplay = UI.settings.windowDuration*data.session.extracellular.srLfp;
        else
            UI.channelScaling = ones(ceil(UI.settings.windowDuration*data.session.extracellular.sr),1)*UI.channelOffset;
            UI.samplesToDisplay = UI.settings.windowDuration*data.session.extracellular.sr;
        end

        UI.dispSamples = floor(linspace(1,UI.samplesToDisplay,UI.Pix_SS));
        UI.nDispSamples = numel(UI.dispSamples);
        UI.elements.lower.windowsSize.String = num2str(UI.settings.windowDuration);
        UI.elements.lower.scaling.String = num2str(UI.settings.scalingFactor);
        UI.plot_axis1.XAxis.TickValues = [0:0.5:UI.settings.windowDuration];
        UI.plot_axis1.XAxis.MinorTickValues = [0:0.01:UI.settings.windowDuration];
        UI.fig.UserData.scalingFactor = UI.settings.scalingFactor;
        UI.fig.UserData.scalingTemporalFactor = UI.settings.columns;
        if UI.settings.plotStyle == 3
            UI.fig.UserData.rangeData = true;
        else
            UI.fig.UserData.rangeData = false;
        end
    end

    function initInputs
        % Handling channeltags
        if exist('parameters','var') && ~isempty(parameters.channeltag)
            idx = find(strcmp(parameters.channeltag,{UI.table.channeltags.Data{:,2}}));
            if ~isempty(idx)
                UI.table.channeltags.Data(idx,3) = {true};
                UI.settings.channelTags.highlight = find([UI.table.channeltags.Data{:,3}]);
                initTraces
            end
        end
        
        if exist('parameters','var') &&~isempty(parameters.events)
            idx = find(strcmp(parameters.events,UI.data.detectecFiles.events));
            if ~isempty(idx)
                UI.settings.eventData = UI.data.detectecFiles.events{idx};
                UI.settings.showEvents(idx) = true;
                showEvents(idx)
            end
        end
    end
    
    function initData(basepath,basename)
        
        % Init data and UI settings
        UI.settings.stream = false;
        
        UI.track = true;
        UI.t_total = 0; % Length of the recording in seconds
        
        % Restting UI and imported data
        UI.settings.showKilosort = false;
        UI.settings.showKlusta = false;
        UI.settings.showSpykingcircus = false;
        UI.settings.normalClick = true;
        UI.settings.channelTags.hide = [];
        UI.settings.channelTags.filter = [];
        UI.settings.channelTags.highlight = [];
        UI.settings.showSpikes = false;
        UI.panel.spikes.showSpikes.Value = 0;
        UI.panel.spikes.populationRate.Value = 0;
        UI.panel.spikesorting.showKilosort.Value = 0;
        UI.panel.spikesorting.showKlusta.Value = 0;
        UI.panel.spikesorting.showSpykingcircus.Value = 0;

        UI.settings.useMetrics = false;
        UI.panel.cell_metrics.useMetrics.Value = 0;
        UI.settings.showEvents = false;
        UI.settings.showTimeseries = false;
        UI.panel.timeseries.show.Value = 0;

        UI.settings.showStates = false;
        UI.panel.states.showStates.Value = 0;
        UI.settings.showBehavior = false;
        UI.panel.behavior.showBehavior.Value = 0;

        UI.settings.intan_showAnalog = false;
        UI.settings.intan_showAux = false;
        UI.settings.intan_showDigital = false;
        UI.settings.spectrogram.show = false;
        
        % Resetting Ephys data analysis
        UI.settings.audioPlay = false;
        UI.panel.audio.playAudio.Value = 0;
        
        UI.settings.instantaneousMetrics.show = false;
        UI.settings.instantaneousMetrics.showPower = false;
        UI.settings.instantaneousMetrics.showSignal = false;
        UI.settings.instantaneousMetrics.showPhase = false;

        UI.panel.instantaneousMetrics.showPower.Value = 0;
        UI.panel.instantaneousMetrics.showSignal.Value = 0;
        UI.panel.instantaneousMetrics.showPhase.Value = 0;

        UI.settings.plotRMSnoiseInset = false;
        UI.panel.RMSnoiseInset.showRMSnoiseInset.Value = 0;
        
        UI.settings.spectrogram.show = false;
        UI.panel.spectrogram.showSpectrogram.Value = 0;
        
        UI.settings.CSD.show = false;
        UI.panel.csd.showCSD.Value = 0;
        
        UI.table.cells.Data = {};
        UI.listbox.cellTypes.String = {''};
        
        % Initialize the data
        UI.data.basepath = basepath;
        UI.data.basename = basename;
        cd(UI.data.basepath)
        
        if ~isfield(data,'session') && exist(fullfile(basepath,[basename,'.session.mat']),'file')
            data.session = loadSession(UI.data.basepath,UI.data.basename);
        elseif ~isfield(data,'session') && exist(fullfile(basepath,[basename,'.xml']),'file')
            data.session = sessionTemplate(UI.data.basepath,'showGUI',false,'basename',basename);
        elseif ~isfield(data,'session')
            data.session = sessionTemplate(UI.data.basepath,'showGUI',true,'basename',basename);
        end
        
        % Loading preferences from session struct
        try
            UI.t0 = data.session.neuroScope2.t0;
            if UI.t0<0
                UI.t0=0;
            end
        end
        UI.t1 = UI.t0;
        UI.t0_track = UI.t0;
        
        % UI.settings.colormap
        try
            if data.session.extracellular.nElectrodeGroups == size(data.session.neuroScope2.colors,1)
                UI.colors = data.session.neuroScope2.colors;
            end
        catch
            UI.colors = eval([UI.settings.colormap,'(',num2str(data.session.extracellular.nElectrodeGroups),')']);
        end
        try
            for i_setting = 1:length(UI.settings.to_save)
                if strcmp(UI.settings.to_save{i_setting},'windowDuration')
                    if data.session.neuroScope2.windowDuration >= 0.001 || data.session.neuroScope2.windowDuration <= 100
                        UI.settings.windowDuration = data.session.neuroScope2.windowDuration;
                        UI.elements.lower.windowsSize.String = num2str(data.session.neuroScope2.windowDuration);
                        resetZoom
                    end
                else
                    UI.settings.(UI.settings.to_save{i_setting}) =  data.session.neuroScope2.(UI.settings.to_save{i_setting});
                    if islogical(UI.settings.(UI.settings.to_save{i_setting})) && UI.settings.(UI.settings.to_save{i_setting}) && isfield(UI.menu.display,UI.settings.to_save{i_setting})
                        UI.menu.display.(UI.settings.to_save{i_setting}).Checked = 'on';
                    end
                end
            end
            UI.panel.general.plotStyle.Value = UI.settings.plotStyle;
            UI.panel.general.colorScale.Value = UI.settings.greyScaleTraces;
            UI.settings.scalingFactor = data.session.neuroScope2.scalingFactor;
            setScalingText            
            UI.plot_axis1.Color = UI.settings.background;
            UI.plot_axis1.XColor = UI.settings.primaryColor;
            
            if UI.settings.showChannelNumbers
                set(UI.plot_axis1,'XLim',[-0.015*UI.settings.windowDuration,UI.settings.windowDuration])
            end
            if UI.settings.narrowPadding
                UI.settings.ephys_padding = 0.015;
            else
                UI.settings.ephys_padding = 0.05;
            end            
        end
        
        UI.settings.leastSignificantBit = data.session.extracellular.leastSignificantBit;
        UI.fig.UserData.leastSignificantBit = UI.settings.leastSignificantBit;
        
        UI.settings.precision = data.session.extracellular.precision;
        
        % Getting notes
        if isfield(data.session.general,'notes')
            UI.panel.notes.text.String = data.session.general.notes;
        end
        
        updateElectrodeGroupsList
        updateChannelTags
        updateChannelList
        updateBrainRegionList
        
        if data.session.extracellular.nElectrodeGroups<2
            UI.settings.extraSpacing = false;
            UI.panel.general.extraSpacing.Value = 0;
        end
        
        UI.fig.Name = ['NeuroScope2   -   session: ', UI.data.basename, ', basepath: ', UI.data.basepath];
        
        if isfield(data.session.extracellular,'fileName') && ~isempty(data.session.extracellular.fileName)
            UI.data.fileName = fullfile(basepath,data.session.extracellular.fileName);
        else
            UI.data.fileName = fullfile(basepath,[UI.data.basename '.dat']);
        end
        UI.fid.ephys = fopen(UI.data.fileName, 'r');
        s1 = dir(UI.data.fileName);
            
        if isfield(data.session.extracellular,'fileNameLFP') && ~isempty(data.session.extracellular.fileNameLFP)
            UI.data.fileNameLFP = fullfile(basepath,data.session.extracellular.fileNameLFP);
        elseif exist(fullfile(basepath,[UI.data.basename '.lfp']),'file')
            UI.data.fileNameLFP = fullfile(basepath,[UI.data.basename '.lfp']);
        elseif exist(fullfile(basepath,[UI.data.basename '.eeg']),'file')
            UI.data.fileNameLFP = fullfile(basepath,[UI.data.basename '.eeg']);
        else
            UI.data.fileNameLFP = fullfile(basepath,[UI.data.basename '.lfp']);
        end
        UI.fid.lfp = fopen(UI.data.fileNameLFP, 'r');
        s2 = dir(UI.data.fileNameLFP);
            
        if ~isfield(UI,'priority')
            UI.priority = 'dat';
        elseif strcmpi(UI.priority,'dat')
            UI.settings.plotStyle = 2;
            UI.panel.general.plotStyle.Value = UI.settings.plotStyle;
        elseif strcmpi(UI.priority,'lfp')
            UI.settings.plotStyle = 4;
            UI.panel.general.plotStyle.Value = UI.settings.plotStyle;
        end
        
        if ~isempty(s1) && ~strcmp(UI.priority,'lfp')
            filesize = s1.bytes;
            UI.t_total = filesize/(data.session.extracellular.nChannels*data.session.extracellular.sr*2);
        elseif ~isempty(s2)
            filesize = s2.bytes;
            UI.t_total = filesize/(data.session.extracellular.nChannels*data.session.extracellular.srLfp*2);
            UI.settings.plotStyle = 4;
            UI.panel.general.plotStyle.Value = UI.settings.plotStyle;
        else
            warning('NeuroScope2: Binary data does not exist')
        end
        UI.forceNewData = true;
        
        % Detecting CellExplorer/Buzcode files
        UI.data.detectecFiles = detectCellExplorerFiles(UI.data.basepath,UI.data.basename);
        
        % Events: basename.*.events.mat
        updateEventsDataList
        
        % Timeseries: basename.*.timeseries.mat
        updateTimeSeriesDataList2
        
        if isfield(UI.data.detectecFiles,'states') && ~isempty(UI.data.detectecFiles.states)
            UI.panel.states.files.String = UI.data.detectecFiles.states;
            UI.settings.statesData = UI.data.detectecFiles.states{1};
        else
            UI.panel.states.files.String = {''};
        end
        if isfield(UI.data.detectecFiles,'behavior') && ~isempty(UI.data.detectecFiles.behavior)
            UI.panel.behavior.files.String = UI.data.detectecFiles.behavior;
            UI.settings.behaviorData = UI.data.detectecFiles.behavior{1};
        else
            UI.panel.behavior.files.String = {''};
        end
        
        % Timeseries files
        updateTimeSeriesDataList
        
        % Defining flexible panel heights for lists of electrode groups, channel tags and analog and digital timeseries
        tableHeights_ElectrodeGroups = max([data.session.extracellular.nElectrodeGroups*18+50,200]);
        if isfield(UI,'channelTags') && ~isempty(UI.channelTags)
            nTags = numel(UI.channelTags);
        else
            nTags = 1;
        end
        tableHeights_ChannelTags = nTags*18+30;
        
        if isfield(data.session,'timeSeries') && ~isempty(data.session.timeSeries)
            nfiles = numel(fieldnames(data.session.timeSeries));
        else
            nfiles = 0;
        end
        tableHeights_Timeseries3 = nfiles*18+30;
        
        set(UI.panel.general.main, 'MinimumHeights',[65 210 tableHeights_ElectrodeGroups 35 tableHeights_ChannelTags 35 50 30 tableHeights_Timeseries3]);
        UI.panel.general.main1.MinimumHeights = 605 + tableHeights_ElectrodeGroups + tableHeights_ChannelTags + tableHeights_Timeseries3;
        
        % Defining flexible panel heights for events and timeseries files
        if isfield(UI.data.detectecFiles,'timeSeries') && ~isempty(data.session.timeSeries)
            nfiles = numel(UI.data.detectecFiles.events);
        else
            nfiles = 0;
        end
        tableHeights_Events = nfiles*18+50;
        
        if isfield(UI.data.detectecFiles,'timeseries')
            nfiles = numel(UI.data.detectecFiles.timeseries);
        else
            nfiles = 0;
        end
        tableHeights_TimeSeries = nfiles*18+30;
        
        set(UI.panel.other.main, 'MinimumHeights',[tableHeights_Events 150 100 150 tableHeights_TimeSeries 40]);
        UI.panel.other.main1.MinimumHeights = 520 + tableHeights_Events + tableHeights_TimeSeries;
        
        
        % Generating epoch interval-visualization
        delete(UI.epochAxes.Children)
        if isfield(data.session,'epochs')
            epochVisualization(data.session.epochs,UI.epochAxes,0,1); 
            if UI.t_total>0
                set(UI.epochAxes,'XLim',[0,UI.t_total])
            end
        end
        
        % Generating Probe layout visualization (Channel coordinates)
        UI.settings.chanCoordsToPlot = 1:data.session.extracellular.nChannels;
        delete(UI.chanCoordsAxes.Children)
        if isfield(data.session.extracellular,'chanCoords') && isfield(data.session.extracellular.chanCoords,'x') &&~isempty(data.session.extracellular.chanCoords.x) && ~isempty(data.session.extracellular.chanCoords.y)
            chanCoordsVisualization(data.session.extracellular.chanCoords,UI.chanCoordsAxes);
            updateChanCoordsColorHighlight
            
            image_toolbox_installed = isToolboxInstalled('Image Processing Toolbox');
            if ~verLessThan('matlab', '9.5') && image_toolbox_installed
                x_lim_data = [min(data.session.extracellular.chanCoords.x),max(data.session.extracellular.chanCoords.x)];
                y_lim_data = [min(data.session.extracellular.chanCoords.y),max(data.session.extracellular.chanCoords.y)];
                x_padding = 0.03*diff(x_lim_data);
                y_padding = 0.03*diff(y_lim_data);
                UI.plotpoints.roi_ChanCoords = drawrectangle(UI.chanCoordsAxes,'Position',[x_lim_data(1)-x_padding,y_lim_data(1)-y_padding,1.06*diff(x_lim_data),1.06*diff(y_lim_data)],'LineWidth',2,'FaceAlpha',0.1,'Deletable',false,'FixedAspectRatio',false);
                addlistener(UI.plotpoints.roi_ChanCoords,'ROIMoved',@updateChanCoordsPlot);
            end
        end
        
        setRecentSessions
    end
    
    function setRecentSessions
        if isdeployed
            CellExplorer_path = pwd;
        else
            [CellExplorer_path,~,~] = fileparts(which('CellExplorer.m'));
            CellExplorer_path = fullfile(CellExplorer_path,'calc_CellMetrics');
        end
        if exist(fullfile(CellExplorer_path,'data_NeuroScope2.mat'))
            load(fullfile(CellExplorer_path,'data_NeuroScope2.mat'),'recentSessions');
            sameSession = (ismember(recentSessions.basepaths,basepath) & ismember(recentSessions.basenames,basename));
            recentSessions.basepaths(sameSession) = [];
            recentSessions.basenames(sameSession) = [];
            recentSessions.basepaths{end+1} = basepath;
            recentSessions.basenames{end+1} = basename;
        else
            recentSessions.basepaths{1} = basepath;
            recentSessions.basenames{1} = basename;
        end
        if ~verLessThan('matlab', '9.3')
            menuLabel = 'Text';
            menuSelectedFcn = 'MenuSelectedFcn';
        else
            menuLabel = 'Label';
            menuSelectedFcn = 'Callback';
        end
        if isfield(UI.menu.file.recentSessions,'ops')
            delete(UI.menu.file.recentSessions.ops);
            UI.menu.file.recentSessions.ops = [];
        end
        for i = 1:min([numel(recentSessions.basepaths),15])
            UI.menu.file.recentSessions.ops(i) = uimenu(UI.menu.file.recentSessions.main,menuLabel,fullfile(recentSessions.basepaths{end-i+1}, recentSessions.basenames{end-i+1}),menuSelectedFcn,@loadFromRecentFiles);
        end
        try
            save(fullfile(CellExplorer_path,'data_NeuroScope2.mat'),'recentSessions');
        end
    end

    function moveSlider(src,evnt)
        sliderMovedManually = true;
        UI.settings.stream = false;
        s1 = dir(UI.data.fileName);
        s2 = dir(UI.data.fileNameLFP);
        if ~isempty(s1)
            filesize = s1.bytes;
            UI.t_total = filesize/(data.session.extracellular.nChannels*data.session.extracellular.sr*2);
        elseif ~isempty(s2)
            filesize = s2.bytes;
            UI.t_total = filesize/(data.session.extracellular.nChannels*data.session.extracellular.srLfp*2);
        end        
    end
    
    function movingSlider(src,evnt)
        if sliderMovedManually
            UI.t0 = valid_t0((UI.t_total-UI.settings.windowDuration)*evnt.AffectedObject.Value/100);
            UI.elements.lower.time.String = num2str(UI.t0);
            setTimeText(UI.t0)
            
            if ~UI.settings.stickySelection
                UI.selectedChannels = [];
                UI.selectedUnits = [];
                UI.selectedUnits = [];
                UI.selectedUnitsColors = [];
            end
            
            % Plotting data
            plotData;
            
            % Updating epoch axes
            if ishandle(epoch_plotElements.t0)
                delete(epoch_plotElements.t0)
            end
            epoch_plotElements.t0 = line(UI.epochAxes,[UI.t0,UI.t0],[0,1],'color','k', 'HitTest','off','linewidth',1);
            UI.settings.stream = false;            
        end
        sliderMovedManually = true;
    end
    
    function p1 = plotStates(statesData,clr)
        statesData = statesData - UI.t0;
        ydata = [0 1];
        p1 = patch(UI.plot_axis1,double([statesData,flip(statesData,2)])',[ydata(1);ydata(1);ydata(2);ydata(2)]*ones(1,size(statesData,1)),clr,'EdgeColor',clr,'HitTest','off');
        alpha(p1,0.3);
    end
    
    function finishIntervalSelection(actionType)
        if polygon1.cleanExit
            n_points = numel(polygon1.coords);
            n_even_points = floor(n_points/2)*2;
            selectedIntervals = reshape(polygon1.coords(1:n_even_points),2,[])';
            states = sort(selectedIntervals,2);
            if size(states,1)>1
                states = ConsolidateIntervals(states);
            end
            if ~isfield(data.events.(UI.settings.eventData),'added_intervals')
                data.events.(UI.settings.eventData).added_intervals = [];
            end
            if actionType == 2
                if size([data.events.(UI.settings.eventData).added_intervals;states],1)>1
                    data.events.(UI.settings.eventData).added_intervals = ConsolidateIntervals([data.events.(UI.settings.eventData).added_intervals;states]);
                else
                    data.events.(UI.settings.eventData).added_intervals = [data.events.(UI.settings.eventData).added_intervals;states];
                end
                UI.elements.lower.performance.String = 'Intervals added';
                UI.settings.addEventonClick = 0;
            elseif actionType == 3
                if ~isempty(data.events.(UI.settings.eventData).added_intervals)
                    data.events.(UI.settings.eventData).added_intervals = SubtractIntervals(data.events.(UI.settings.eventData).added_intervals,states);
                end
                UI.elements.lower.performance.String = 'Intervals removed';
                UI.settings.addEventonClick = 0;
            end
%             plotStates(states);
        end
        uiresume(UI.fig);
    end
    
    function ClickPlot(~,~)
        UI.settings.stream = false;
        % handles clicks on the main axes
        um_axes = get(UI.plot_axis1,'CurrentPoint');
        t_click = um_axes(1,1);
        if UI.settings.plotTracesInColumns
            t_click = (t_click-max(UI.settings.channels_relative_offset(UI.channelOrder((t_click-UI.settings.channels_relative_offset(UI.channelOrder))>0))))*UI.settings.columns;
        end
        t_click = t_click+UI.t0;
        selectiontype = get(UI.fig, 'selectiontype');

        switch selectiontype

            case 'normal' % left mouse button                
                
                if UI.settings.addEventonClick == 1 % Adding new event
                    data.events.(UI.settings.eventData).added = unique([data.events.(UI.settings.eventData).added;t_click]);
                    UI.elements.lower.performance.String = ['Event added: ',num2str(t_click),' sec'];
                    UI.settings.addEventonClick = 0;
                    uiresume(UI.fig);

                elseif UI.settings.addEventonClick > 1 % Adding new interval
                    polygon1.coords = [polygon1.coords;t_click];
                    polygon1.counter = polygon1.counter +1;
                    
                    n_points = numel(polygon1.coords);
                    polygon1.handle2(polygon1.counter) = line(UI.plot_axis1,polygon1.coords(end)*[1,1]- UI.t0,[0,1],'color',[0.5 0.5 0.5], 'HitTest','off');
                    if n_points>1
                        n_even_points = floor(n_points/2)*2;
                        statesData = polygon1.coords(1:n_even_points);
                        statesData = reshape(statesData,2,[])';
                        if UI.settings.addEventonClick == 2
                            clr = 'b';
                        else
                            clr = 'r';
                        end
                        polygon1.handle(polygon1.counter) = plotStates(statesData(end,:),clr);
                    else
                        % polygon1.handle(polygon1.counter) = [];
                    end
                    
                    if polygon1.counter > 1
                        set(polygon1.handle2(polygon1.counter-1),'Visible','off');
                    end
                else % Otherwise show cursor time
                    UI.elements.lower.performance.String = ['Cursor: ',num2str(t_click),' sec'];
                end
                
            case 'alt' % right mouse button

                % Removing/flagging events
                if UI.settings.addEventonClick == 1 && ~isempty(data.events.(UI.settings.eventData).added)
                    idx3 = find(data.events.(UI.settings.eventData).added >= UI.t0 & data.events.(UI.settings.eventData).added <= UI.t0+UI.settings.windowDuration);
                    if any(idx3)
                        eventsInWindow = data.events.(UI.settings.eventData).added(idx3);
                        [~,idx] = min(abs(eventsInWindow-t_click));
                        t_click = data.events.(UI.settings.eventData).added(idx3(idx));
                        data.events.(UI.settings.eventData).added(idx3(idx)) = [];
                        UI.elements.lower.performance.String = ['Event deleted: ',num2str(t_click),' sec'];
                        UI.settings.addEventonClick = 0;
                        uiresume(UI.fig);
                    else
                        UI.settings.addEventonClick = 0;
                        uiresume(UI.fig);
                    end

                elseif UI.settings.addEventonClick > 1 % Adding or delete interval
                    if polygon1.counter >= 2
                        polygon1.cleanExit = 1;
                    end
                    set(UI.fig,'Pointer','arrow')
                    finishIntervalSelection(UI.settings.addEventonClick)
                    UI.settings.addEventonClick = 0;
                end
                
            case 'extend' % middle mouse button

                if UI.settings.addEventonClick > 1 % Adding new interval
                    
                    if polygon1.counter > 1                        
                        polygon1.coords = polygon1.coords(1:end-1);
                        set(polygon1.handle(polygon1.counter),'Visible','off');
                        set(polygon1.handle2(polygon1.counter),'Visible','off');
                        polygon1.counter = polygon1.counter-1;
                        polygon1.handle2(polygon1.counter) = line(UI.plot_axis1,polygon1.coords(end)*[1,1],[0,1],'color',[0.5 0.5 0.5], 'HitTest','off');                        
                    elseif polygon1.counter < 2
                        UI.settings.addEventonClick = 0;
                        set(UI.fig,'Pointer','arrow')
                        uiresume(UI.fig);
                    end

                elseif UI.settings.showSpikes && ~UI.settings.normalClick
                    
                    [~,In] = min(hypot((spikes_raster.x(:)-um_axes(1,1)),(spikes_raster.y(:)-um_axes(1,2))));
                    UID = spikes_raster.UID(In);
                    if ~isempty(UID)
                        highlightUnits(UID,[]);
                        [UI.selectedUnits,idxColors] = unique([UID,UI.selectedUnits],'stable');
                        UI.selectedUnitsColors = [UI.colorLine(UI.iLine,:); UI.selectedUnitsColors];
                        UI.selectedUnitsColors = UI.selectedUnitsColors(idxColors,:);
                        UI.elements.lower.performance.String = ['Unit(s) selected: ',num2str(UI.selectedUnits)];
                    end

                else
                    
                    channels = sort([UI.channels{UI.settings.electrodeGroupsToPlot}]);
                    x1 = (ones(size(ephys.traces(:,channels),2),1)*[1:size(ephys.traces(:,channels),1)]/size(ephys.traces(:,channels),1)*UI.settings.windowDuration/UI.settings.columns)'+UI.settings.channels_relative_offset(channels);
                    y1 = (ephys.traces(:,channels)-UI.channelOffset(channels));
                    [~,In] = min(hypot((x1(:)-um_axes(1,1)),(y1(:)-um_axes(1,2))));
                    In = unique(floor(In/size(x1,1)))+1;
                    In = channels(In);

                    if ismember(In,UI.selectedChannels)
                        idxColors = In==UI.selectedChannels;
                        UI.selectedChannels(idxColors) = [];
                        UI.selectedChannelsColors(idxColors,:) = [];
                        trace_color = [0.5 0.5 0.5];
                        highlightTraces(In,trace_color)
                        if isempty(UI.selectedChannels)
                            UI.elements.lower.performance.String = ['Removed channel ',num2str(In)];
                        elseif length(UI.selectedChannels) == 1
                            UI.elements.lower.performance.String = ['Removed channel ',num2str(In),'. Remaining selected channel: ',num2str(UI.selectedChannels)];
                        else
                            UI.elements.lower.performance.String = ['Removed channel ',num2str(In),'. Remaining selected channels: ',num2str(UI.selectedChannels)];
                        end

                    else
                        highlightTraces(In,[])
                        [UI.selectedChannels,idxColors] = unique([In,UI.selectedChannels],'stable');
                        UI.selectedChannelsColors = [UI.colorLine(UI.iLine,:); UI.selectedChannelsColors];
                        UI.selectedChannelsColors = UI.selectedChannelsColors(idxColors,:);
                        if length(UI.selectedChannels) == 1
                            UI.elements.lower.performance.String = ['Selected channel: ',num2str(UI.selectedChannels)];
                        else
                            UI.elements.lower.performance.String = ['Selected channels: ',num2str(UI.selectedChannels)];
                        end
                    end
                end                
            case 'open'
                resetZoom
                
            otherwise
                UI.elements.lower.performance.String = ['Cursor: ',num2str(t_click),' sec'];
        end
    end
    
    function ClickEpochs(~,~)
        UI.settings.stream = false;
        um_axes = get(UI.epochAxes,'CurrentPoint');
        t0_CurrentPoint = um_axes(1,1);
        
        switch get(UI.fig, 'selectiontype')
            case 'normal' % left mouse button
                
                % t0
                UI.t0 = t0_CurrentPoint;
                uiresume(UI.fig);
                
            case 'alt' % right mouse button
                
                % Onset of selected epoch
                t_startTimes = [];
                for i = 1:numel(data.session.epochs)
                    if isfield(data.session.epochs{i},'startTime')
                        t_startTimes(i) = data.session.epochs{i}.startTime;
                    else
                        t_startTimes(i) = 0;
                    end
                end
                t_startTimes = t_startTimes(t_startTimes < t0_CurrentPoint);
                if ~isempty(t_startTimes)
                    UI.t0 = max(t_startTimes);
                    uiresume(UI.fig);
                end
                
            case 'extend' % middle mouse button
                
                % Goes to closest event
                try
                    t_events = data.events.(UI.settings.eventData).time;
                    [~,idx] = min(abs(t_events-t0_CurrentPoint));
                    UI.t0 = t_events(idx)-UI.settings.windowDuration/2;
                    uiresume(UI.fig);
                end
            case 'open' % double click
                
            otherwise
                
        end
    end
    
    function resetZoom
        if UI.settings.showChannelNumbers
            set(UI.plot_axis1,'XLim',[-0.015*UI.settings.windowDuration,UI.settings.windowDuration],'YLim',[0,1])
        else
            set(UI.plot_axis1,'XLim',[0,UI.settings.windowDuration],'YLim',[0,1])
        end
    end
                
    function updateChanCoordsPlot(~,~)
        UI.settings.stream = false;
        pos = UI.plotpoints.roi_ChanCoords.Position;
        x1 = [pos(1),pos(1)+pos(3),pos(1)+pos(3),pos(1)];
        y1 = [pos(2),pos(2),pos(2)+pos(4),pos(2)+pos(4)];
        UI.settings.chanCoordsToPlot = find(inpolygon(data.session.extracellular.chanCoords.x,data.session.extracellular.chanCoords.y, x1 ,y1));
        
        updateChanCoordsColorHighlight
        initTraces
        uiresume(UI.fig);
    end
    
    function updateChanCoordsColorHighlight
        if isfield(data.session.extracellular,'chanCoords')
            try
                delete(UI.plotpoints.chanCoords)
            end
            for fn = 1:data.session.extracellular.nElectrodeGroups
                channels = intersect(data.session.extracellular.electrodeGroups.channels{fn},UI.settings.chanCoordsToPlot,'stable');
                if ~isempty(channels)
                    UI.plotpoints.chanCoords(fn) = line(UI.chanCoordsAxes,data.session.extracellular.chanCoords.x(channels),data.session.extracellular.chanCoords.y(channels),'color',0.8*UI.colors(fn,:),'Marker','.','linestyle','none','HitTest','off','markersize',10);
                end
            end
        end
    end

    function t0 = valid_t0(t0)
        t0 = min([max([0,floor(t0*data.session.extracellular.sr)/data.session.extracellular.sr]),UI.t_total-UI.settings.windowDuration]);
        if isnan(t0)
            t0 = 0;
        end
    end
    
    function [channel_out,channel_valid] = validate_channel(channel_field)
        channel_valid = true;
        channelnumber = str2num(channel_field);
        if isempty(channelnumber)
            channel_out = [];
        elseif isnumeric(channelnumber) && channelnumber > 0 && channelnumber <= data.session.extracellular.nChannels
            channel_out = ceil(channelnumber);
        else
            channel_out = 1;
            MsgLog('The channel is not valid',4);
            channel_valid = false;
        end
    end

    function editElectrodeGroups(~,~)
        UI.settings.electrodeGroupsToPlot = find([UI.table.electrodeGroups.Data{:,1}]);
        initTraces
        uiresume(UI.fig);
    end
    
    function editBrainregionList(~,~)
        brainRegions = fieldnames(data.session.brainRegions);
        UI.settings.brainRegionsToHide = brainRegions(~[UI.table.brainRegions.Data{:,1}]);
        initTraces
        uiresume(UI.fig);
    end
    
    function buttonChannelList(~,~)
        channelOrder = [data.session.extracellular.electrodeGroups.channels{:}];
        UI.settings.channelList = channelOrder(UI.listbox.channelList.Value);
        initTraces
        uiresume(UI.fig);
    end
    
    function editChannelTags(~,evnt)
        if evnt.Indices(1,2) == 6 & isnumeric(str2num(evnt.NewData))
            data.session.channelTags.(UI.table.channeltags.Data{evnt.Indices(1,1),2}).channels = str2num(evnt.NewData);
            initTraces
            uiresume(UI.fig);
        else
            UI.settings.channelTags.highlight = find([UI.table.channeltags.Data{:,3}]);
            UI.settings.channelTags.filter = find([UI.table.channeltags.Data{:,4}]);
            UI.settings.channelTags.hide = find([UI.table.channeltags.Data{:,5}]);
            initTraces
            uiresume(UI.fig);
        end
    end

    function ClicktoSelectFromTable(~,evnt)
        % Change colors of electrode groups
        if ~isempty(evnt.Indices) && size(evnt.Indices,1) == 1 && evnt.Indices(2) == 2
            colorpick = UI.colors(evnt.Indices(1),:);
            colorpick = userSetColor(colorpick,'Electrode group color');
            UI.colors(evnt.Indices(1),:) = colorpick;
            classColorsHex = rgb2hex(UI.colors);
            classColorsHex = cellstr(classColorsHex(:,2:end));
            colored_string = strcat('<html><BODY bgcolor="',classColorsHex','">&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;</BODY></html>');
            UI.table.electrodeGroups.Data{evnt.Indices(1),2} = colored_string{evnt.Indices(1)};
            initTraces
            updateChannelList
            updateChanCoordsColorHighlight
            uiresume(UI.fig);
        end
    end

    function ClicktoSelectFromTable2(~,evnt)
        if ~isempty(evnt.Indices) && size(evnt.Indices,1) == 1 && evnt.Indices(2) == 1 && isfield(UI,'colors_tags')
            colorpick = UI.colors_tags(evnt.Indices(1),:);
            colorpick = userSetColor(colorpick,'Channel tag color');
            UI.colors_tags(evnt.Indices(1),:) = colorpick;
            classColorsHex = rgb2hex(UI.colors_tags);
            classColorsHex = cellstr(classColorsHex(:,2:end));
            colored_string = strcat('<html><BODY bgcolor="',classColorsHex','">&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;</BODY></html>');
            UI.table.channeltags.Data{evnt.Indices(1),1} = colored_string{evnt.Indices(1)};
            uiresume(UI.fig);
        end
    end
    
    function table_events_click(~,evnt)
        if ~isempty(evnt.Indices) && size(evnt.Indices,1) == 1 && evnt.Indices(2) == 1 && isfield(UI,'colors_events')
            colorpick = UI.colors_events(evnt.Indices(1),:);
            colorpick = userSetColor(colorpick,'Channel tag color');
            UI.colors_events(evnt.Indices(1),:) = colorpick;
            classColorsHex = rgb2hex(UI.colors_events);
            classColorsHex = cellstr(classColorsHex(:,2:end));
            colored_string = strcat('<html><BODY bgcolor="',classColorsHex','">&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;</BODY></html>');
            UI.table.events_data.Data{evnt.Indices(1),1} = colored_string{evnt.Indices(1)};
            uiresume(UI.fig);
        end
    end
    
    function table_timeseries_click(~,evnt)
        if isfield(UI.data.detectecFiles,'timeseries') && ~isempty(evnt.Indices) && size(evnt.Indices,1) == 1 && evnt.Indices(2) == 1
            colorpick = UI.colors_timeseries(evnt.Indices(1),:);
            colorpick = userSetColor(colorpick,'Channel tag color');
            UI.colors_timeseries(evnt.Indices(1),:) = colorpick;
            classColorsHex = rgb2hex(UI.colors_timeseries);
            classColorsHex = cellstr(classColorsHex(:,2:end));
            colored_string = strcat('<html><BODY bgcolor="',classColorsHex','">&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;</BODY></html>');
            UI.table.timeseries_data.Data{evnt.Indices(1),1} = colored_string{evnt.Indices(1)};
            uiresume(UI.fig);
        end
    end

    function changePlotStyle(~,~)
        UI.settings.plotStyle = UI.panel.general.plotStyle.Value;
        initTraces
        UI.forceNewData = true;
        uiresume(UI.fig);
    end

    function changeColorScale(~,~)
        UI.settings.greyScaleTraces = UI.panel.general.colorScale.Value;
        uiresume(UI.fig);
    end

    function plotEnergy(~,~)
        if  UI.panel.general.plotEnergy.Value==1
            UI.settings.plotEnergy = true;
        else
            UI.settings.plotEnergy = false;
        end
        answer = UI.panel.general.energyWindow.String;
        if  ~isempty(answer) & isnumeric(str2num(answer))
            UI.settings.energyWindow = str2num(answer);
        end
        uiresume(UI.fig);
    end

    function extraSpacing(~,~)
        if UI.panel.general.extraSpacing.Value == 1
            UI.settings.extraSpacing = true;
        else
            UI.settings.extraSpacing = false;
        end
        initTraces
        uiresume(UI.fig);
    end
    
    function changeTraceFilter(src,~)
        if strcmp(src.Style,'edit')
            UI.panel.general.filterToggle.Value = 1;
        end
        if UI.panel.general.filterToggle.Value == 0
            UI.settings.filterTraces = false;
        else
            UI.settings.filterTraces = true;
            UI.settings.filter.lowerBand = str2num(UI.panel.general.lowerBand.String);
            UI.settings.filter.higherBand = str2num(UI.panel.general.higherBand.String);
            if int_gt_0(UI.settings.filter.lowerBand,data.session.extracellular.sr) && int_gt_0(UI.settings.filter.higherBand,data.session.extracellular.sr) 
                UI.settings.filterTraces = false;
            elseif int_gt_0(UI.settings.filter.lowerBand,data.session.extracellular.sr) && ~int_gt_0(UI.settings.filter.higherBand,data.session.extracellular.sr)
                [UI.settings.filter.b1, UI.settings.filter.a1] = butter(3, UI.settings.filter.higherBand/(data.session.extracellular.sr/2), 'low');
            elseif int_gt_0(UI.settings.filter.higherBand,data.session.extracellular.sr) && ~int_gt_0(UI.settings.filter.lowerBand,data.session.extracellular.sr)
                [UI.settings.filter.b1, UI.settings.filter.a1] = butter(3, UI.settings.filter.lowerBand/(data.session.extracellular.sr/2), 'high');
            else
                [UI.settings.filter.b1, UI.settings.filter.a1] = butter(3, [UI.settings.filter.lowerBand,UI.settings.filter.higherBand]/(data.session.extracellular.sr/2), 'bandpass');
            end
        end
        uiresume(UI.fig);
    end

    function updateElectrodeGroupsList
        % Updates the list of electrode groups
        
        if isfield(data.session.extracellular,'electrodeGroups')
            tableData = {};
            if isfield(data.session.extracellular,'electrodeGroups') && isfield(data.session.extracellular.electrodeGroups,'channels') && isnumeric(data.session.extracellular.electrodeGroups.channels)
                data.session.extracellular.electrodeGroups.channels = num2cell(data.session.extracellular.electrodeGroups.channels,2)';
            end
            
            if ~isempty(data.session.extracellular.electrodeGroups.channels) && ~isempty(data.session.extracellular.electrodeGroups.channels{1})
                nTotal = numel(data.session.extracellular.electrodeGroups.channels);
            else
                nTotal = 0;
            end
            classColorsHex = rgb2hex(UI.colors);
            classColorsHex = cellstr(classColorsHex(:,2:end));
            colored_string = strcat('<html><BODY bgcolor="',classColorsHex','">&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;</BODY></html>');
            
            for fn = 1:nTotal
                tableData{fn,1} = true;
                tableData{fn,2} = colored_string{fn};
                tableData{fn,3} = [num2str(fn),' (',num2str(length(data.session.extracellular.electrodeGroups.channels{fn})),')'];
                tableData{fn,4} = ['<HTML>' num2str(data.session.extracellular.electrodeGroups.channels{fn})];
                if isfield(data.session.extracellular.electrodeGroups,'label') && numel(data.session.extracellular.electrodeGroups.label)>=fn && ~isempty(data.session.extracellular.electrodeGroups.label{fn})
                    tableData{fn,5} = data.session.extracellular.electrodeGroups.label{fn};
                else
                    tableData{fn,5} = '';
                end
                
            end
            UI.table.electrodeGroups.Data = tableData;
        else
            UI.table.electrodeGroups.Data = {false,'','','',''};
        end
        UI.settings.electrodeGroupsToPlot = 1:data.session.extracellular.nElectrodeGroups;
    end
    
    function updateChannelList
        if isfield(data.session.extracellular,'electrodeGroups')
            
            UI.settings.channelList = [data.session.extracellular.electrodeGroups.channels{:}];
            colored_string = DefineChannelListColors;
            UI.listbox.channelList.String = colored_string(UI.settings.channelList);
            UI.listbox.channelList.Max = numel(UI.settings.channelList);
            UI.listbox.channelList.Value = 1:numel(UI.settings.channelList);
        else
            UI.settings.channelList = [];
            UI.listbox.channelList.String = {''};
            UI.listbox.channelList.Max = 1;
            UI.listbox.channelList.Value = 1;
        end
        
        function colored_string = DefineChannelListColors
            groupColorsHex = rgb2hex(UI.colors*0.7);
            groupColorsHex = cellstr(groupColorsHex(:,2:end));
            channelColorsHex = repmat({''},numel(UI.settings.channelList),1);
            for fn = 1:size(groupColorsHex,1)
                channelColorsHex(data.session.extracellular.electrodeGroups.channels{fn}) = groupColorsHex(fn);
            end
            
            classNumbers = cellstr(num2str([1:length(UI.settings.channelList)]'));
            classNumbers = regexprep(classNumbers, ' ', '&nbsp;&nbsp;');
            colored_string = strcat('<html><BODY bgcolor="',channelColorsHex,'">&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;<font color="white">Channel&nbsp;&nbsp;', classNumbers, '&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;</font></BODY>',classNumbers, '.&nbsp;</html>');
        end
    end
    
    function updateBrainRegionList
        if isfield(data.session,'brainRegions') & ~isempty(data.session.brainRegions)
            brainRegions = fieldnames(data.session.brainRegions);
            tableData = {};
            for fn = 1:numel(brainRegions)
                tableData{fn,1} = true;
                tableData{fn,2} = brainRegions{fn};
                tableData{fn,3} = [num2str(data.session.brainRegions.(brainRegions{fn}).channels)];
                tableData{fn,4} = [num2str(data.session.brainRegions.(brainRegions{fn}).electrodeGroups)];
            end
            UI.settings.brainRegionsToHide = [];
        else
            tableData = {false,'','',''};
        end
        UI.table.brainRegions.Data =  tableData;
    end
    
    function updateEventsDataList        
        % Updates the list of events
        tableData = {};
        if isfield(UI.data.detectecFiles,'events') && ~isempty(UI.data.detectecFiles.events)
            UI.colors_events = lines(numel(UI.data.detectecFiles.events))*0.8;
            classColorsHex = rgb2hex(UI.colors_events);
            classColorsHex = cellstr(classColorsHex(:,2:end));
            colored_string = strcat('<html><BODY bgcolor="',classColorsHex','">&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;</BODY></html>');
            eventFiles = UI.data.detectecFiles.events;
            nTags = numel(eventFiles);
            for i = 1:nTags
                tableData{i,1} = colored_string{i};
                tableData{i,2} = eventFiles{i};
                tableData{i,3} = false;
                tableData{i,4} = false;
                tableData{i,5} = false;
            end
            UI.table.events_data.Data = tableData;
            UI.settings.showEventsBelowTrace = false(1,numel(UI.data.detectecFiles.events));
            UI.settings.showEvents = false(1,numel(UI.data.detectecFiles.events));
        else
            UI.table.events_data.Data =  {''};
        end
    end
    
    function updateTimeSeriesDataList2
        if isfield(UI.data.detectecFiles,'timeseries') && ~isempty(UI.data.detectecFiles.timeseries)
            UI.panel.timeseries.files.String = UI.data.detectecFiles.timeseries;
            UI.settings.timeseriesData = UI.data.detectecFiles.timeseries{1};
        else
            UI.panel.timeseries.files.String = {''};
        end
        
        % Updates the list of timeseries
        tableData = {'','',false,'Full trace','',''};
        if isfield(UI.data.detectecFiles,'timeseries') && ~isempty(UI.data.detectecFiles.timeseries)
            UI.colors_timeseries = lines(numel(UI.data.detectecFiles.timeseries))*0.8;
            classColorsHex = rgb2hex(UI.colors_timeseries);
            classColorsHex = cellstr(classColorsHex(:,2:end));
            colored_string = strcat('<html><BODY bgcolor="',classColorsHex','">&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;</BODY></html>');
            timeseriesFiles = UI.data.detectecFiles.timeseries;
            nTags = numel(timeseriesFiles);
            for i = 1:nTags
                tableData{i,1} = colored_string{i}; % Color
                tableData{i,2} = timeseriesFiles{i}; % Name
                tableData{i,3} = false; % Show
                tableData{i,4} = 'Full trace'; % Range selection {'Full trace','Window','Custom'}
                tableData{i,5} = '0 1'; % Custom range
                tableData{i,6} = ''; % Channels
                UI.settings.timeseries.(timeseriesFiles{i}).show = false;
                UI.settings.timeseries.(timeseriesFiles{i}).custom = [0 1];
            end
            UI.table.timeseries_data.Data = tableData;
            UI.settings.showTimeseries = false(1,numel(UI.data.detectecFiles.timeseries));
        else
            UI.table.timeseries_data.Data =  tableData;
        end
    end
    
    function updateTimeSeriesDataList % binary files
        if isfield(data.session,'timeSeries') & ~isempty(data.session.timeSeries)
            timeSeries = fieldnames(data.session.timeSeries);
            tableData = {};
            for fn = 1:numel(timeSeries)
                tableData{fn,1} = false;
                tableData{fn,2} = timeSeries{fn};
                tableData{fn,3} = (data.session.timeSeries.(timeSeries{fn}).fileName);
                tableData{fn,4} = [num2str(data.session.timeSeries.(timeSeries{fn}).nChannels)];
                
                % Defining channel labels
                UI.settings.traceLabels.(timeSeries{fn}) = strcat(repmat({timeSeries{fn}},data.session.timeSeries.(timeSeries{fn}).nChannels,1),num2str([1:data.session.timeSeries.(timeSeries{fn}).nChannels]'));
                if isfield(data.session,'inputs')
                    inputs = fieldnames(data.session.inputs);
                    for i = 1:numel(inputs)
                        try
                            UI.settings.traceLabels.(timeSeries{fn})(data.session.inputs.(inputs{i}).channels) = {[UI.settings.traceLabels.(timeSeries{fn}){data.session.inputs.(inputs{i}).channels},': ',inputs{i}]};
                        end
                    end
                end
            end
        else
            tableData = {false,'','',''};
        end
        UI.table.timeseriesdata.Data =  tableData;
    end

    function updateChannelTags
        % Updates the list of channelTags
        tableData = {};
        if isfield(data.session,'channelTags') && ~isempty(fieldnames(data.session.channelTags))
            UI.colors_tags = jet(numel(fieldnames(data.session.channelTags)))*0.8;
            classColorsHex = rgb2hex(UI.colors_tags);
            classColorsHex = cellstr(classColorsHex(:,2:end));
            colored_string = strcat('<html><BODY bgcolor="',classColorsHex','">&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;</BODY></html>');
            UI.channelTags = fieldnames(data.session.channelTags);
            nTags = numel(UI.channelTags);
            for i = 1:nTags
                tableData{i,1} = colored_string{i};
                tableData{i,2} = UI.channelTags{i};
                tableData{i,3} = false;
                tableData{i,4} = false;
                tableData{i,5} = false;
                if isfield(data.session.channelTags.(UI.channelTags{i}),'channels')
                    tableData{i,6} = num2str(data.session.channelTags.(UI.channelTags{i}).channels);
                else
                    tableData{i,6} = '';
                end
                if isfield(data.session.channelTags.(UI.channelTags{i}),'groups')
                    tableData{i,7} = num2str(data.session.channelTags.(UI.channelTags{i}).groups);
                else
                    tableData{i,7} = '';
                end
                
            end
            UI.table.channeltags.Data = tableData;
        else
            UI.table.channeltags.Data =  {''};
        end
    end

% % Spikes functions
    function toogleDetectSpikes(~,~)
        if UI.panel.general.detectSpikes.Value == 1
            UI.settings.detectSpikes = true;
            if isnumeric(str2num(UI.panel.general.detectThreshold.String)) && ~isempty(str2num(UI.panel.general.detectThreshold.String)) && ~isnan(str2num(UI.panel.general.detectThreshold.String))
                UI.settings.spikesDetectionThreshold = str2num(UI.panel.general.detectThreshold.String);
            end
        else
            UI.settings.detectSpikes = false;
        end
        initTraces
        uiresume(UI.fig);
    end

    function toogleDetectEvents(~,~)
        if UI.panel.general.detectEvents.Value == 1
            UI.settings.detectEvents = true;
            if isnumeric(str2num(UI.panel.general.eventThreshold.String))
                UI.settings.eventThreshold = str2num(UI.panel.general.eventThreshold.String);
            end
        else
            UI.settings.detectEvents = false;
        end
        initTraces
        uiresume(UI.fig);
    end

% % Event functions
    function setEventData(src,evnt)
        table_call_column = evnt.Indices(2);
        table_call_row = evnt.Indices(1);
        value1 = evnt.EditData;
        eventName = UI.data.detectecFiles.events{table_call_row};
        if table_call_column==3 % Show
            if value1
                UI.settings.eventData = eventName;
                UI.settings.showEvents(table_call_row) = true;
                showEvents(table_call_row)
                UI.table.events_data.Data(:,4) = {false};
                UI.table.events_data.Data{table_call_row,4} = true;                
                setActiveEvents(value1)
            else
                UI.settings.showEvents(table_call_row) = false;
                UI.table.events_data.Data{table_call_row,4} = false;
                if strcmp(UI.settings.eventData,eventName) && any(UI.settings.showEvents)
                    idx = find(UI.settings.showEvents);
                    eventName = UI.data.detectecFiles.events{idx(1)};
                    UI.table.events_data.Data{idx(1),4} = true;    
                    UI.settings.eventData = eventName;
                    setActiveEvents(true)
                else
                    setActiveEvents(false)
                end
                initTraces
                uiresume(UI.fig);
            end
        elseif table_call_column==4 % Active
            if value1                
                if src.Data{table_call_row,3}
                    UI.settings.eventData = eventName;
                    UI.table.events_data.Data(:,4) = {false};
                    UI.table.events_data.Data{table_call_row,4} = true;
                    setActiveEvents(value1)
                else
                    UI.table.events_data.Data{table_call_row,4} = false;
                end
                uiresume(UI.fig);
            else
                UI.table.events_data.Data{table_call_row,4} = true;
            end
        elseif table_call_column==5 % Below
            if value1
                UI.settings.showEventsBelowTrace(table_call_row) = true;
            else
                UI.settings.showEventsBelowTrace(table_call_row) = false;
            end
            initTraces
            uiresume(UI.fig);
        end
    end

    function showEvents(table_call_row)
        % Loading event data
        if exist(fullfile(basepath,[basename,'.',UI.settings.eventData,'.events.mat']),'file')
            if ~isfield(data,'events') || ~isfield(data.events,UI.settings.eventData)
                data.events.(UI.settings.eventData) = loadStruct(UI.settings.eventData,'events','session',data.session);
                if ~isfield(data.events.(UI.settings.eventData),'time')
                    if isfield(data.events.(UI.settings.eventData),'peaks')
                        data.events.(UI.settings.eventData).time = data.events.(UI.settings.eventData).peaks;
                    elseif isfield(data.events.(UI.settings.eventData),'timestamps')
                        data.events.(UI.settings.eventData).time = data.events.(UI.settings.eventData).timestamps(:,1);
                    end
                end
            end
            UI.settings.showEvents(table_call_row) = true;
        else
            UI.settings.showEvents(table_call_row) = false;
            UI.table.events_data.Data{table_call_row,3} = false;
        end
        initTraces
        uiresume(UI.fig);
    end
    
    function setActiveEvents(state_value1)
        if ishandle(epoch_plotElements.events)
            delete(epoch_plotElements.events)
        end
        
        if state_value1
            UI.panel.events.eventNumber.String = num2str(UI.settings.iEvent);
            UI.panel.events.eventCount.String = ['nEvents: ' num2str(numel(data.events.(UI.settings.eventData).time))];
            if ~isfield(data.events.(UI.settings.eventData),'flagged')
                data.events.(UI.settings.eventData).flagged = [];
            end
            UI.panel.events.flagCount.String = ['nFlags: ', num2str(numel(data.events.(UI.settings.eventData).flagged))];
            t_stamps = data.events.(UI.settings.eventData).time;
            epoch_plotElements.events = line(UI.epochAxes,t_stamps,0.1*ones(size(t_stamps)),'color',UI.settings.primaryColor, 'HitTest','off','Marker',UI.settings.rasterMarker,'LineStyle','none');
        else
            UI.panel.events.eventNumber.String = '';
            UI.panel.events.flagCount.String = '';
            UI.panel.events.eventCount.String =  '';
        end
    end

    function processing_steps(~,~)
        % Determines if processing steps should be plotted
        if UI.panel.events.processing_steps.Value == 1
            UI.settings.processing_steps = true;
        else
            UI.settings.processing_steps = false;
        end
        initTraces
        uiresume(UI.fig);
    end

    function showBehaviorBelowTrace(~,~)
        if UI.panel.behavior.showBehaviorBelowTrace.Value == 1
            UI.settings.showBehaviorBelowTrace = true;
        else
            UI.settings.showBehaviorBelowTrace = false;
        end
        initTraces
        uiresume(UI.fig);
    end

    function plotBehaviorLinearized(~,~)
        if UI.panel.behavior.plotBehaviorLinearized.Value == 1
            UI.settings.plotBehaviorLinearized = true;
        else
            UI.settings.plotBehaviorLinearized = false;
            UI.panel.behavior.plotBehaviorLinearized.Value = 0;
        end
        initTraces
        uiresume(UI.fig);
    end

    function showEventsIntervals(~,~)
        if UI.panel.events.showEventsIntervals.Value == 1
            UI.settings.showEventsIntervals = true;
        else
            UI.settings.showEventsIntervals = false;
        end
        initTraces
        uiresume(UI.fig);
    end
    
    function nextEvent(~,~)
        UI.settings.stream = false;
        if any(UI.settings.showEvents)
            idx = 1:numel(data.events.(UI.settings.eventData).time);
            UI.settings.iEvent1 = find(data.events.(UI.settings.eventData).time(idx)>UI.t0+UI.settings.windowDuration/2,1);
            UI.settings.iEvent = idx(UI.settings.iEvent1);
            if ~isempty(UI.settings.iEvent)
                UI.panel.events.eventNumber.String = num2str(UI.settings.iEvent);
                UI.t0 = data.events.(UI.settings.eventData).time(UI.settings.iEvent)-UI.settings.windowDuration/2;
                uiresume(UI.fig);
            end            
        end
    end

    function gotoEvents(~,~)
        UI.settings.stream = false;
        if any(UI.settings.showEvents)
            UI.settings.iEvent = str2num(UI.panel.events.eventNumber.String);
            if ~isempty(UI.settings.iEvent) && isnumeric(UI.settings.iEvent) && UI.settings.iEvent <= numel(data.events.(UI.settings.eventData).time) && UI.settings.iEvent > 0
                UI.panel.events.eventNumber.String = num2str(UI.settings.iEvent);
                UI.t0 = data.events.(UI.settings.eventData).time(UI.settings.iEvent)-UI.settings.windowDuration/2;
                uiresume(UI.fig);
            end
        end
    end
    function previousEvent(~,~)
        UI.settings.stream = false;
        if any(UI.settings.showEvents)
            idx = 1:numel(data.events.(UI.settings.eventData).time);
            UI.settings.iEvent1 = find(data.events.(UI.settings.eventData).time(idx)<UI.t0+UI.settings.windowDuration/2,1,'last');
            UI.settings.iEvent = idx(UI.settings.iEvent1);
            if ~isempty(UI.settings.iEvent)
                UI.panel.events.eventNumber.String = num2str(UI.settings.iEvent);
                UI.t0 = data.events.(UI.settings.eventData).time(UI.settings.iEvent)-UI.settings.windowDuration/2;
                uiresume(UI.fig);
            end
        end
    end

    function randomEvent(~,~)
        UI.settings.stream = false;
        if any(UI.settings.showEvents)
            UI.settings.iEvent = ceil(numel(data.events.(UI.settings.eventData).time)*rand(1));
            UI.panel.events.eventNumber.String = num2str(UI.settings.iEvent);
            UI.t0 = data.events.(UI.settings.eventData).time(UI.settings.iEvent)-UI.settings.windowDuration/2;
            uiresume(UI.fig);
        end
    end

    function nextPowerEvent(~,~)
        UI.settings.stream = false;
        if any(UI.settings.showEvents) && isfield(data.events.(UI.settings.eventData),'peakNormedPower')
            [~,idx] = sort(data.events.(UI.settings.eventData).peakNormedPower,'descend');
            test = find(idx==UI.settings.iEvent);
            if ~isempty(test) && test < numel(idx) && test >= 1
                UI.settings.iEvent = idx(test+1);
                UI.panel.events.eventNumber.String = num2str(UI.settings.iEvent);
                UI.t0 = data.events.(UI.settings.eventData).time(UI.settings.iEvent)-UI.settings.windowDuration/2;
                uiresume(UI.fig);
            end
        end
    end

    function previousPowerEvent(~,~)
        UI.settings.stream = false;
        if any(UI.settings.showEvents) && isfield(data.events.(UI.settings.eventData),'peakNormedPower')
            [~,idx] = sort(data.events.(UI.settings.eventData).peakNormedPower,'descend');
            test = find(idx==UI.settings.iEvent);
            if ~isempty(test) &&  test <= numel(idx) && test > 1
                UI.settings.iEvent = idx(test-1);
                UI.panel.events.eventNumber.String = num2str(UI.settings.iEvent);
                UI.t0 = data.events.(UI.settings.eventData).time(UI.settings.iEvent)-UI.settings.windowDuration/2;
                uiresume(UI.fig);
            end
        end
    end

    function maxPowerEvent(~,~)
        UI.settings.stream = false;
        if any(UI.settings.showEvents) && isfield(data.events.(UI.settings.eventData),'peakNormedPower')
            [~,UI.settings.iEvent] = max(data.events.(UI.settings.eventData).peakNormedPower);
            UI.panel.events.eventNumber.String = num2str(UI.settings.iEvent);
            UI.t0 = data.events.(UI.settings.eventData).time(UI.settings.iEvent)-UI.settings.windowDuration/2;
            uiresume(UI.fig);
        end
    end

    function minPowerEvent(~,~)
        UI.settings.stream = false;
        if any(UI.settings.showEvents) && isfield(data.events.(UI.settings.eventData),'peakNormedPower')
            [~,UI.settings.iEvent] = min(data.events.(UI.settings.eventData).peakNormedPower);
            UI.panel.events.eventNumber.String = num2str(UI.settings.iEvent);
            UI.t0 = data.events.(UI.settings.eventData).time(UI.settings.iEvent)-UI.settings.windowDuration/2;
            uiresume(UI.fig);
        end
    end
    
    function flagEvent(~,~)
        UI.settings.stream = false;
        if any(UI.settings.showEvents)
            if ~isfield(data.events.(UI.settings.eventData),'flagged')
                data.events.(UI.settings.eventData).flagged = [];
            end
            idx = find(data.events.(UI.settings.eventData).time==UI.t0+UI.settings.windowDuration/2);
            if ~isempty(idx)
                if any(data.events.(UI.settings.eventData).flagged == idx)
                    idx2 = find(data.events.(UI.settings.eventData).flagged == idx);
                    data.events.(UI.settings.eventData).flagged(idx2) = [];
                else
                    data.events.(UI.settings.eventData).flagged = unique([data.events.(UI.settings.eventData).flagged;idx]);
                end
            end
            UI.panel.events.flagCount.String = ['nFlags: ', num2str(numel(data.events.(UI.settings.eventData).flagged))];
            uiresume(UI.fig);
        end
    end
    
    function addEvent(~,~)
        UI.settings.stream = false;
        if any(UI.settings.showEvents)
            if ~isfield(data.events.(UI.settings.eventData),'added')
                data.events.(UI.settings.eventData).added = [];
            end
            UI.settings.addEventonClick = 1;
            UI.streamingText = text(UI.plot_axis1,UI.settings.windowDuration/2,1,'Adding events (single timestamps) to active events: Left click axes to add event - right click event to delete nearest added event','FontWeight', 'Bold','VerticalAlignment', 'top','HorizontalAlignment','center','color',UI.settings.primaryColor);
        else
            MsgLog('Before adding events you must open an event file',2);
        end
    end
    
    function addInterval(~,~)
        UI.settings.stream = false;
        if any(UI.settings.showEvents)
            if ~isfield(data.events.(UI.settings.eventData),'added_intervals')
                data.events.(UI.settings.eventData).added = [];
            end
            UI.settings.addEventonClick = 2;
            UI.streamingText = text(UI.plot_axis1,UI.settings.windowDuration/2,1,'Adding event intervals to active events: Left mouse click to define boundaries of intervals -  complete with right mouse click, cancel last point with middle mouse click','FontWeight', 'Bold','VerticalAlignment', 'top','HorizontalAlignment','center','color',UI.settings.primaryColor);
            
            hold(UI.plot_axis1, 'on');
            polygon1.handle = gobjects(0);
            polygon1.counter = 0;
            polygon1.cleanExit = 0;
            polygon1.coords = [];
            polygon1.handle2 = [];
            set(UI.fig,'Pointer','left')
        else
            MsgLog('Before adding events you must open an event file',2);
        end
    end
    
    function removeInterval(~,~)
        UI.settings.stream = false;
        if any(UI.settings.showEvents)
            if ~isfield(data.events.(UI.settings.eventData),'added_intervals')
                data.events.(UI.settings.eventData).added = [];
            end
            UI.settings.addEventonClick = 3;
            UI.streamingText = text(UI.plot_axis1,UI.settings.windowDuration/2,1,'Removing event intervals from active events: Left click axes to define interval - complete with right click, cancel last point with middle click','FontWeight', 'Bold','VerticalAlignment', 'top','HorizontalAlignment','center','color',UI.settings.primaryColor);
            
            hold(UI.plot_axis1, 'on');
            polygon1.handle = gobjects(0);
            polygon1.counter = 0;
            polygon1.cleanExit = 0;
            polygon1.coords = [];
            polygon1.handle2 = [];
            set(UI.fig,'Pointer','left')
        else
            MsgLog('Before adding events you must open an event file',2);
        end
    end
    
    function saveEvent(~,~) % Saving event file
        if isfield(data,'events') && isfield(data.events,UI.settings.eventData)
            data1 = data.events.(UI.settings.eventData);
            saveStruct(data1,'events','session',data.session,'dataName',UI.settings.eventData);
            MsgLog(['Events from ', UI.settings.eventData,' succesfully saved to basepath'],2);
        end
    end
    
    function saveCellMetrics(~,~) % Saving cell_metrics
        if isfield(data,'cell_metrics')
        data1 = data.cell_metrics;
        saveStruct(data1,'cellinfo','session',data.session,'dataName','cell_metrics');
        MsgLog('Cell metrics succesfully saved to basepath',2);
        end
    end
    
    function openCellExplorer(~,~)
        if isfield(data,'cell_metrics')
            data.cell_metrics = CellExplorer('metrics',data.cell_metrics);
        end
    end

    % Time series
    function setTimeseriesData(src,evnt)
        if isfield(UI.data.detectecFiles,'timeseries')
            table_call_column = evnt.Indices(2);
            table_call_row = evnt.Indices(1);
            value1 = evnt.EditData;
            timeserieData = UI.data.detectecFiles.timeseries{table_call_row};
            if table_call_column==3 % Show
                if value1
                    UI.settings.timeserieData = timeserieData;
                    initTimeseries(timeserieData,table_call_row)
                else
                    UI.settings.timeseries.(timeserieData).show = false;
                    uiresume(UI.fig);
                end
            elseif table_call_column==4 % Range selection
                UI.settings.timeseries.(timeserieData).range = value1;
                uiresume(UI.fig);
            elseif table_call_column==5 % Custom range
                boundaries = eval(['[',value1,']']);
                if isnumeric(boundaries) && length(boundaries) == 2
                    UI.settings.timeseries.(timeserieData).custom = boundaries(1:2);
                end
                UI.table.timeseries_data.Data{table_call_row,5} = num2str(UI.settings.timeseries.(timeserieData).custom);
                uiresume(UI.fig);
            elseif table_call_column==6 % Channels
                try
                    channelist = eval(['[',value1,']']);
                catch
                    return
                end
                if UI.settings.timeseries.(timeserieData).show && isnumeric(channelist) && all(ismember(channelist,1:size(data.timeseries.(timeserieData).data,2)))
                    UI.settings.timeseries.(timeserieData).channels = channelist;
                    UI.table.timeseries_data.Data{table_call_row,6} = num2str(UI.settings.timeseries.(timeserieData).channels);
                end
                uiresume(UI.fig);
            end
        end
    end
    
    function initTimeseries(timeserieData,table_call_row)
        % Loading timeserie data
        if exist(fullfile(basepath,[basename,'.',timeserieData,'.timeseries.mat']),'file')
            if ~isfield(data,'timeseries') || ~isfield(data.timeseries,timeserieData)
                data.timeseries.(timeserieData) = loadStruct(timeserieData,'timeseries','session',data.session);
                if size(data.timeseries.(timeserieData).timestamps,2)>1
                    data.timeseries.(timeserieData).timestamps = data.timeseries.(timeserieData).timestamps';
                end
                if size(data.timeseries.(timeserieData).data,1) ~= size(data.timeseries.(timeserieData).timestamps,1)
                    data.timeseries.(timeserieData).data = data.timeseries.(timeserieData).data';
                end                
            end
            UI.settings.timeseries.(timeserieData).show = true;
            UI.settings.timeseries.(timeserieData).range = 'Full trace';
            UI.table.timeseries_data.Data{table_call_row,4} = 'Full trace'; % Range selection
            UI.settings.timeseries.(timeserieData).custom = [0 1];
            UI.table.timeseries_data.Data{table_call_row,5} = '0 1'; % Custom limits
            UI.settings.timeseries.(timeserieData).channels = 1:size(data.timeseries.(timeserieData).data,2);
            UI.table.timeseries_data.Data{table_call_row,6} = num2str(UI.settings.timeseries.(timeserieData).channels); % Channels
            
            UI.settings.timeseries.(timeserieData).lowerBoundary = min(data.timeseries.(timeserieData).data);
            UI.settings.timeseries.(timeserieData).upperBoundary = max(data.timeseries.(timeserieData).data);
        else
            UI.settings.timeseries.(timeserieData).show = false;
            UI.table.timeseries_data.Data{table_call_row,3} = false;
        end
        uiresume(UI.fig);
    end

% States
    function setStatesData(~,~)
        UI.settings.statesData = UI.panel.states.files.String{UI.panel.states.files.Value};
        UI.settings.showStates = false;
        showStates;
    end

    function showStates(~,~) % States (buzcode)
        if UI.settings.showStates
            UI.settings.showStates = false;
            UI.panel.states.showStates.Value = 0;
        elseif exist(fullfile(basepath,[basename,'.',UI.settings.statesData,'.states.mat']),'file')
            if ~isfield(data,'states') || ~isfield(data.states,UI.settings.statesData)
                data.states.(UI.settings.statesData) = loadStruct(UI.settings.statesData,'states','session',data.session);
            end
            UI.settings.showStates = true;
            UI.panel.states.showStates.Value = 1;
            UI.panel.states.statesNumber.String = '1';
            if ~isfield(data.states.(UI.settings.statesData),'idx')
                if isfield(data.states.(UI.settings.statesData),'ints')
                    states = data.states.(UI.settings.statesData).ints;
                else
                    states = data.states.(UI.settings.statesData);
                end
                statenames = fieldnames(states);
                states_new = [];
                timestamps = [];
                for i = 1:length(statenames)
                    states_new = [states_new;i*ones(size(states.(statenames{i})))];
                    timestamps = [timestamps;states.(statenames{i})(:,1)];
                end                
                data.states.(UI.settings.statesData).idx.states = states_new;
                data.states.(UI.settings.statesData).idx.timestamps = timestamps;
                data.states.(UI.settings.statesData).idx.statenames = statenames;
            end
            UI.panel.states.statesCount.String = ['nStates: ' num2str(numel(data.states.(UI.settings.statesData).idx.timestamps))];
        else
            UI.settings.showStates = false;
            UI.panel.states.showStates.Value = 0;
        end
        initTraces
        uiresume(UI.fig);
    end

    function previousStates(~,~)
        UI.settings.stream = false;
        if UI.settings.showStates
            timestamps = getTimestampsFromStates;
            idx = find(timestamps<UI.t0,1,'last');
            if ~isempty(idx)
                UI.t0 = timestamps(idx);
                UI.panel.states.statesNumber.String = num2str(idx);
                uiresume(UI.fig);
            end
        end
    end

    function nextStates(~,~)
        UI.settings.stream = false;
        if UI.settings.showStates
            timestamps = getTimestampsFromStates;
            idx = find(timestamps>UI.t0,1);
            if ~isempty(idx)
                UI.t0 = timestamps(idx);
                UI.panel.states.statesNumber.String = num2str(idx);
                uiresume(UI.fig);
            end
        end
    end

    function gotoState(~,~)
        UI.settings.stream = false;
        if UI.settings.showStates
            timestamps = getTimestampsFromStates;
            idx =  str2num(UI.panel.states.statesNumber.String);
            if ~isempty(idx) && isnumeric(idx) && idx>0 && idx<=numel(timestamps)
                UI.t0 = timestamps(idx);
                uiresume(UI.fig);
            end
        end
    end
    
    function timestamps = getTimestampsFromStates
        timestamps = [];
        if isfield(data.states.(UI.settings.statesData),'ints')
            states1  = data.states.(UI.settings.statesData).ints;
        else
            states1  = data.states.(UI.settings.statesData);
        end
        timestamps1 = cellfun(@(fn) states1.(fn), setdiff(fieldnames(states1),{'idx','processinginfo','detectorinfo'}), 'UniformOutput', false);
        timestamps1 = vertcat(timestamps1{:});
        timestamps = [timestamps,timestamps1(:,1)];
        timestamps = sort(timestamps);
    end

    % Behavior
    function setBehaviorData(~,~)
        UI.settings.behaviorData = UI.panel.behavior.files.String{UI.panel.behavior.files.Value};
        UI.settings.showBehavior = false;
        showBehavior;
    end
    
    function showBehavior(~,~) % Behavior (CellExplorer/buzcode)
        if UI.panel.behavior.showBehavior.Value == 0
            UI.settings.showBehavior = false;
        elseif exist(fullfile(basepath,[basename,'.',UI.settings.behaviorData,'.behavior.mat']),'file')
            if ~isfield(data,'behavior') || ~isfield(data.behavior,UI.settings.behaviorData)
                temp = loadStruct(UI.settings.behaviorData,'behavior','session',data.session);
                if ~isfield(temp,'timestamps')
                    MsgLog(['Failed to load behavior data - no timestamps: ' UI.settings.behaviorData],4);
                    UI.panel.behavior.showBehavior.Value = 0;
                    UI.settings.showBehavior = false;
                    return
                end
                data.behavior.(UI.settings.behaviorData) = temp;
                data.behavior.(UI.settings.behaviorData).limits.x = [min(data.behavior.(UI.settings.behaviorData).position.x),max(data.behavior.(UI.settings.behaviorData).position.x)];
                data.behavior.(UI.settings.behaviorData).limits.y = [min(data.behavior.(UI.settings.behaviorData).position.y),max(data.behavior.(UI.settings.behaviorData).position.y)];
                if ~isfield(data.behavior.(UI.settings.behaviorData).limits,'linearized') && isfield(data.behavior.(UI.settings.behaviorData).position,'linearized')
                    data.behavior.(UI.settings.behaviorData).limits.linearized = [min(data.behavior.(UI.settings.behaviorData).position.linearized),max(data.behavior.(UI.settings.behaviorData).position.linearized)];
                end
                if ~isfield(data.behavior.(UI.settings.behaviorData),'sr')
                    data.behavior.(UI.settings.behaviorData).sr = 1/diff(data.behavior.(UI.settings.behaviorData).timestamps(1:2));
                end
                if isfield(data.behavior.(UI.settings.behaviorData),'trials') && ~isempty(fieldnames(data.behavior.(UI.settings.behaviorData).trials))
                    UI.panel.behavior.showTrials.String = ['Trial data', fieldnames(data.behavior.(UI.settings.behaviorData).trials)];
                end
            end
            UI.settings.showBehavior = true;
        end
        initTraces
        uiresume(UI.fig);
    end

    function nextBehavior(~,~)
        UI.settings.stream = false;
        if UI.settings.showBehavior
            UI.t0 = data.behavior.(UI.settings.behaviorData).timestamps(end)-UI.settings.windowDuration;
            uiresume(UI.fig);
        end
    end
    
    function previousBehavior(~,~)
        UI.settings.stream = false;
        if UI.settings.showBehavior
            UI.t0 = data.behavior.(UI.settings.behaviorData).timestamps(1);
            uiresume(UI.fig);
        end
    end
    
    function initAnalysisToolsMenu
        if ~verLessThan('matlab', '9.3')
            menuLabel = 'Text';
            menuSelectedFcn = 'MenuSelectedFcn';
        else
            menuLabel = 'Label';
            menuSelectedFcn = 'Callback';
        end
        
        analysisTools = what('analysis_tools');
        analysisToolsPackages = analysisTools.packages;
        
        for j = 1:length(analysisToolsPackages)
            analysisTools = what(['analysis_tools/',analysisToolsPackages{j}]);
            analysisToolsOptions = cellfun(@(X) X(1:end-2),analysisTools.m,'UniformOutput', false);
            analysisToolsOptions(strcmpi(analysisToolsOptions,'wrapper_example')) = [];
            if ~isempty(analysisToolsOptions)
                UI.menu.analysis.(analysisToolsPackages{j}).topMenu = uimenu(UI.menu.analysis.topMenu,menuLabel,analysisToolsPackages{j},'Tag',analysisToolsPackages{j});
                for i = 1:length(analysisToolsOptions)
                    UI.menu.analysis.(analysisToolsPackages{j}).(analysisToolsOptions{i}) = uimenu(UI.menu.analysis.(analysisToolsPackages{j}).topMenu,menuLabel,analysisToolsOptions{i},menuSelectedFcn,@analysis_wrapper,'Tag',analysisToolsOptions{i});
                end
            end
        end
    end

    function summaryFigure(~,~)
        UI.settings.stream = false;
        % Spike data
        summaryfig = figure('name','Summary figure','Position',[50 50 1200 900],'visible','off');
        ax1 = axes(summaryfig,'XLim',[0,UI.t_total],'title','Summary figure','YLim',[0,1],'YTickLabel',[],'Color',UI.settings.background,'Position',[0.05 0.07 0.9 0.88],'XColor','k','TickDir','out'); hold on, 
        xlabel('Time (s)')
        
        if UI.settings.showSpikes
            dataRange_spikes = UI.dataRange.spikes;
            temp = reshape(struct2array(UI.dataRange),2,[]);
            if ~UI.settings.spikesBelowTrace && ~isempty(temp(2,temp(2,:)<1))
                UI.dataRange.spikes(1) = max(temp(2,temp(2,:)<1));
            end
            UI.dataRange.spikes(2) = 0.97;
            spikesBelowTrace = UI.settings.spikesBelowTrace;
            UI.settings.spikesBelowTrace = true;
            
            plotSpikeData(0,UI.t_total,UI.settings.primaryColor,ax1)
            
            UI.dataRange.spikes = dataRange_spikes;
            UI.settings.spikesBelowTrace = spikesBelowTrace;
            
            if UI.settings.useSpikesYData
                spikes_sorting = UI.settings.spikesYData;
            elseif UI.settings.useMetrics
                spikes_sorting = UI.params.sortingMetric;
            else
                spikes_sorting = 'UID';
            end
            ylabel(['Neurons (sorting / ydata: ' spikes_sorting,')'],'interpreter','none'), 
        end
        
        % KiloSort data
        if UI.settings.showKilosort
            plotKilosortData(UI.t0,UI.t0+UI.settings.windowDuration,'c')
        end
        
        % Klusta data
        if UI.settings.showKlusta
            plotKlustaData(UI.t0,UI.t0+UI.settings.windowDuration,'c')
        end
        
        % Spykingcircus data
        if UI.settings.showSpykingcircus
            plotSpykingcircusData(UI.t0,UI.t0+UI.settings.windowDuration,'c')
        end
        
        % Event data
        if any(UI.settings.showEvents)
            for i = 1:numel(UI.settings.showEvents)
                if UI.settings.showEvents(i)
                    eventName = UI.data.detectecFiles.events{i};
                    plotEventData(eventName,0,UI.t_total,UI.colors_events(i,:))
                end
            end
        end
        
        % Time series
        if any([UI.table.timeseries_data.Data{:,3}])
            for i = 1:length(UI.data.detectecFiles.timeseries)
                timeserieName = UI.data.detectecFiles.timeseries{i};
                if UI.settings.timeseries.(timeserieName).show
                    plotTimeseriesData(timeserieName,UI.t0,UI.t0+UI.settings.windowDuration,UI.colors_timeseries(i,:),2);                    
                end
            end
        end

        % States data
        if UI.settings.showStates
            plotTemporalStates(0,UI.t_total)
        end
        
        % Behavior
        if UI.settings.showBehavior
            plotBehavior(0,UI.t_total,'m')
        end
        
        % Trials
        if UI.settings.showTrials
            plotTrials(0,UI.t_total)
        end
        
        %Plotting epochs
        if isfield(data.session,'epochs')
            colors = 1-(1-lines(numel(data.session.epochs)))*0.7;
            for i = 1:numel(data.session.epochs)
                if isfield(data.session.epochs{i},'startTime') && isfield(data.session.epochs{i},'stopTime')
                    p1 = patch(ax1,[data.session.epochs{i}.startTime data.session.epochs{i}.stopTime  data.session.epochs{i}.stopTime data.session.epochs{i}.startTime],[0.990 0.990 0.999 0.999],colors(i,:),'EdgeColor',colors(i,:)*0.5,'HitTest','off');
                    alpha(p1,0.8);
                end
                if isfield(data.session.epochs{i},'startTime') && isfield(data.session.epochs{i},'name') && isfield(data.session.epochs{i},'behavioralParadigm')
                    text(data.session.epochs{i}.startTime,1,{data.session.epochs{i}.name;data.session.epochs{i}.behavioralParadigm},'color','k','VerticalAlignment', 'bottom','Margin',1,'interpreter','none','HitTest','off') % 
%                     text(ax1,data.session.epochs{i}.startTime,1,[' ',num2str(i)],'color','k','VerticalAlignment', 'top','Margin',1,'interpreter','none','HitTest','off','fontweight', 'bold')
                elseif isfield(data.session.epochs{i},'startTime') && isfield(data.session.epochs{i},'name')
                    text(ax1,data.session.epochs{i}.startTime,1,[' ',data.session.epochs{i}.name],'color','k','VerticalAlignment', 'bottom','Margin',1,'interpreter','none','HitTest','off','fontweight', 'bold')
                elseif isfield(data.session.epochs{i},'startTime')
                    text(ax1,data.session.epochs{i}.startTime,1,[' ',num2str(i)],'color','k','VerticalAlignment', 'bottom','Margin',1,'interpreter','none','HitTest','off','fontweight', 'bold')
                end
            end
        end
        
        % Plotting current timepoint
        plot([UI.t0;UI.t0],[ax1.YLim(1);ax1.YLim(2)],'--b'); 
        
        movegui(summaryfig,'center'), set(summaryfig,'visible','on')
    end
    
    function analysis_wrapper(src,~)
        folder1 = src.Parent.Tag;
        function1 = src.Tag;
        
        % Older version of Matlab  did not support below line so introduced the switch
        % out = analysis_tools.(folder1).(function1)('ephys',ephys,'UI',UI,'data',data);
        switch(folder1)
            case 'behavior'
                out = analysis_tools.behavior.(function1)('ephys',ephys,'UI',UI,'data',data);
            case 'cell_metrics'
                out = analysis_tools.cell_metrics.(function1)('ephys',ephys,'UI',UI,'data',data);
            case 'events'
                out = analysis_tools.events.(function1)('ephys',ephys,'UI',UI,'data',data);
            case 'lfp'
                out = analysis_tools.lfp.(function1)('ephys',ephys,'UI',UI,'data',data);
            case 'session'
                out = analysis_tools.session.(function1)('ephys',ephys,'UI',UI,'data',data);
            case 'spikes'
                out = analysis_tools.spikes.(function1)('ephys',ephys,'UI',UI,'data',data);
            case 'states'
                out = analysis_tools.states.(function1)('ephys',ephys,'UI',UI,'data',data);
            case 'timeseries'
                out = analysis_tools.timeseries.(function1)('ephys',ephys,'UI',UI,'data',data);
            case 'traces'
                out = analysis_tools.traces.(function1)('ephys',ephys,'UI',UI,'data',data);
        end
        % Checking if any actions should be performed after the analysis is complete
        if ~isempty(out) && isfield(out,'refresh') && isfield(out.refresh, 'events') && out.refresh.events
            % Detecting CellExplorer/Buzcode files
            UI.data.detectecFiles = detectCellExplorerFiles(UI.data.basepath,UI.data.basename);

            % Refreshing events: basename.*.events.mat
            updateEventsDataList

            out.refresh.events = false;

        elseif ~isempty(out) && isfield(out,'refresh') && isfield(out.refresh, 'timeseries') && out.refresh.timeseries
            % Detecting CellExplorer/Buzcode files
            UI.data.detectecFiles = detectCellExplorerFiles(UI.data.basepath,UI.data.basename);

            % Refreshing timeseries: basename.*.timeseries.mat
            updateTimeSeriesDataList2

            out.refresh.timeseries = false;
        elseif ~isempty(out) && isfield(out,'refresh') && isfield(out.refresh, 'spikes') && out.refresh.spikes
            % Detecting CellExplorer/Buzcode files
            data = rmfield(data,'spikes');
            toggleSpikes

            out.refresh.spikes = false;
        end
    end
    
    function plotCSD(~,~)
        % Current source density plot
        % Original code from FMA
        % By Michaël Zugaro
        timeLine = [1:size(ephys.traces,1)]'/size(ephys.traces,1)*UI.settings.windowDuration/UI.settings.columns;
        for iShanks = UI.settings.electrodeGroupsToPlot
            channels = UI.channels{iShanks};
            [~,ia,~] = intersect(UI.channelOrder,channels,'stable');
            channels = UI.channelOrder(ia);
            if numel(channels)>3
                y = ephys.traces(:,channels);
                y = y - repmat(mean(y),length(timeLine),1);
                d = -diff(y,2,2);
                d = interp2(d);
                
                d = d(1:2:size(d,1),:);
                timeLine1 = timeLine+UI.settings.channels_relative_offset(channels(1));
                multiplier = -linspace(max(UI.channelOffset(channels)),min(UI.channelOffset(channels)),size(d,2));
                pcolor(UI.plot_axis1,timeLine1,multiplier,flipud(transpose(d)));
            end
        end

        set(UI.plot_axis1,'clim',[-0.05 0.05])
        shading interp;
    end
    
    function showTrials(~,~)
        if UI.panel.behavior.showTrials.Value == 1
            UI.settings.showTrials = false;
        else
            UI.settings.trialsData = UI.panel.behavior.showTrials.String{UI.panel.behavior.showTrials.Value};
            UI.settings.showTrials = true;
            UI.panel.behavior.trialNumber.String = '1';
            try
                UI.panel.behavior.trialCount.String = ['nTrials: ' num2str(data.behavior.(UI.settings.behaviorData).trials.(UI.settings.trialsData).nTrials)];
            end
        end
        initTraces
        uiresume(UI.fig);
    end

    function nextTrial(~,~)
        UI.settings.stream = false;
        if UI.settings.showTrials
            idx = find(data.behavior.(UI.settings.behaviorData).trials.(UI.settings.trialsData).start>UI.t0,1);
            if isempty(idx)
                idx = 1;
            end
            UI.t0 = data.behavior.(UI.settings.behaviorData).trials.(UI.settings.trialsData).start(idx);
            UI.panel.behavior.trialNumber.String = num2str(idx);
            uiresume(UI.fig);
        end
    end

    function previousTrial(~,~)
        UI.settings.stream = false;
        if UI.settings.showTrials
            idx = find(data.behavior.(UI.settings.behaviorData).trials.(UI.settings.trialsData).start<UI.t0,1,'last');
            if isempty(idx)
                idx = numel(data.behavior.(UI.settings.behaviorData).trials.(UI.settings.trialsData).start);
            end
            UI.t0 = data.behavior.(UI.settings.behaviorData).trials.(UI.settings.trialsData).start(idx);
            UI.panel.behavior.trialNumber.String = num2str(idx);
            uiresume(UI.fig);
        end
    end

    function gotoTrial(~,~)
        UI.settings.stream = false;
        if UI.settings.showTrials
            idx = str2num(UI.panel.behavior.trialNumber.String);
            if ~isempty(idx) && isnumeric(idx) && idx>0 && idx<=numel(data.behavior.(UI.settings.behaviorData).trials.(UI.settings.trialsData).start)
                UI.t0 = data.behavior.(UI.settings.behaviorData).trials.(UI.settings.trialsData).start(idx);
                uiresume(UI.fig);
            end
        end
        
    end
    
    function tooglePopulationRate(~,~)
        if isnumeric(str2num(UI.panel.spikes.populationRateWindow.String))
            UI.settings.populationRateWindow = str2num(UI.panel.spikes.populationRateWindow.String);
        end
        if isnumeric(str2num(UI.panel.spikes.populationRateSmoothing.String))
            UI.settings.populationRateSmoothing = str2num(UI.panel.spikes.populationRateSmoothing.String);
        end
        if UI.panel.spikes.populationRate.Value == 1
            UI.settings.showPopulationRate = true;
            UI.settings.populationRateBelowTrace = true;
%             if UI.panel.spikes.populationRateBelowTrace.Value == 1
%                UI.settings.populationRateBelowTrace = true;
%             else
%                 UI.settings.populationRateBelowTrace = false;
%             end
        else
            UI.settings.showPopulationRate = false;
        end
        initTraces
        uiresume(UI.fig);
    end
    
    function showKilosort(~,~)
        if UI.panel.spikesorting.showKilosort.Value == 1 && ~isfield(data,'spikes_kilosort')
            [file,path] = uigetfile('*.mat','Please select a KiloSort rez file for this session');
            if ~isequal(file,0)
                % Loading rez file
                load(fullfile(path,file),'rez');
                
                % Importing Kilosort data into spikes struct
                if size(rez.st3,2)>4
                    spikeClusters = uint32(rez.st3(:,5));
                    spike_cluster_index = uint32(spikeClusters); % -1 for zero indexing
                else
                    spikeTemplates = uint32(rez.st3(:,2));
                    spike_cluster_index = uint32(spikeTemplates); % -1 for zero indexing
                end
                
                spike_times = uint64(rez.st3(:,1));
                spike_amplitudes = rez.st3(:,3);
                spike_clusters = unique(spike_cluster_index);
                
                UID = 1;
                tol_ms = data.session.extracellular.sr/1100; % 1 ms tolerance in timestamp units
                for i = 1:length(spike_clusters)
                    spikes.ids{UID} = find(spike_cluster_index == spike_clusters(i));
                    tol = tol_ms/max(double(spike_times(spikes.ids{UID}))); % unique values within tol (=within 1 ms)
                    [spikes.ts{UID},ind_unique] = uniquetol(double(spike_times(spikes.ids{UID})),tol);
                    spikes.ids{UID} = spikes.ids{UID}(ind_unique);
                    spikes.times{UID} = spikes.ts{UID}/data.session.extracellular.sr;
                    spikes.cluID(UID) = spike_clusters(i);
                    spikes.total(UID) = length(spikes.ts{UID});
                    spikes.amplitudes{UID} = double(spike_amplitudes(spikes.ids{UID}));
                    try
                        [~,spikes.maxWaveformCh1(UID)] = max(abs(rez.U(:,rez.iNeigh(1,spike_clusters(i)),1)));
                    end
                    UID = UID+1;
                end
                spikes.numcells = numel(spikes.times);
                spikes.spindices = generateSpinDices(spikes.times);
                spikes.spindices(:,3) = spikes.maxWaveformCh1(spikes.spindices(:,2));
                
                data.spikes_kilosort = spikes;
                UI.settings.showKilosort = true;
                uiresume(UI.fig);
                MsgLog(['KiloSort data loaded succesful: ' basename],2)
            else
                UI.settings.showKilosort = false;
                UI.panel.spikesorting.showKilosort.Value = 0;
            end
        elseif UI.panel.spikesorting.showKilosort.Value == 1  && isfield(data,'spikes_kilosort')
            UI.settings.showKilosort = true;
            uiresume(UI.fig);
        else
            UI.settings.showKilosort = false;
            uiresume(UI.fig);
        end
        if UI.panel.spikesorting.kilosortBelowTrace.Value == 1
            UI.settings.kilosortBelowTrace = true;
        else
            UI.settings.kilosortBelowTrace = false;
        end
        initTraces
    end
    
    function showKlusta(~,~)
        if UI.panel.spikesorting.showKlusta.Value == 1 && ~isfield(data,'spikes_klusta')
            [file,path] = uigetfile('*.xml','Please select the klustakwik xml file for this session');
            if ~isequal(file,0)
                basename1 = file(1:end-4);
                spikes = loadSpikes('basepath',path,'basename',basename1,'format','klustakwik','saveMat',false,'getWaveformsFromDat',false,'getWaveformsFromSource',true);
                spikes.spindices = generateSpinDices(spikes.times);
                data.spikes_klusta = spikes;
                UI.settings.showKlusta = true;
                uiresume(UI.fig);
                MsgLog('Klustakwik data loaded succesful',2)
            else
                UI.settings.showKlusta = false;
                UI.panel.spikesorting.showKlusta.Value = 0;
                MsgLog('Failed to load KlustaKwik data',2)
            end
        elseif UI.panel.spikesorting.showKlusta.Value == 1  && isfield(data,'spikes_klusta')
            UI.settings.showKlusta = true;
            uiresume(UI.fig);
        else
            UI.settings.showKlusta = false;
            uiresume(UI.fig);
        end
        if UI.panel.spikesorting.klustaBelowTrace.Value == 1
            UI.settings.klustaBelowTrace = true;
        else
            UI.settings.klustaBelowTrace = false;
        end
        initTraces
    end
    
    function showSpykingcircus(~,~)
        if UI.panel.spikesorting.showSpykingcircus.Value == 1 && ~isfield(data,'spikes_spykingcircus')
            
            [file,path] = uigetfile('*.hdf5','Please select the Spyking Circus file for this session (hdf5 clusters)');
            if ~isequal(file,0)
                % Loading Spyking Circus file
                result_file = fullfile(path,file); % the user should use result.hdf5 which includes spiketimes of all templates (from the last template matching step) 
                info = h5info(result_file);
                templates_file = replace(result_file,'result','templates'); % to read templates.hdf5 file 
                % find max channel and correct for bad channels that are removed
                %preferred_electrodes = double(h5read(templates_file, '/electrodes')); % prefered electrode for every template may not be the maxCh
                bad_channels = data.session.channelTags.Bad.channels;
                bad_channels = sort(bad_channels); % in case they are not stored in Session in ascending order                        
                % extract templates for finding max channel
                temp_shape = double(h5read(templates_file, '/temp_shape'));
                Ne = temp_shape(1);
                Nt = temp_shape(2); 
                N_templates = temp_shape(3)/2; 
                temp_x = double(h5read(templates_file, '/temp_x') + 1);
                temp_y = double(h5read(templates_file, '/temp_y') + 1);
                temp_z = double(h5read(templates_file, '/temp_data'));
                tmp = sparse(temp_x, temp_y, temp_z, Ne*Nt, temp_shape(3));
                templates = reshape(full(tmp(:,1:N_templates)),Nt,Ne,N_templates); %spatiotemporal templates Nt*Ne*N_templates
                maxCh1 = zeros(N_templates,1);
                for i = 1:N_templates
                    template_i = templates(:,:,i);  
                    [~, maxCh1(i,1)] = min(min(template_i,[],1));
                end
                %correct bad channel removal by Spyking_circus 
                for i = 1:length(bad_channels)
                    ch = bad_channels(i); 
                    mask = maxCh1>= ch;
                    maxCh1(mask) = maxCh1(mask)+1; 
                end                
                
                for i = 1: N_templates % which is equal to length(info.Groups(4).Datasets) = number of templates
                    spikes.times{i} = double(h5read(result_file,['/spiketimes/',info.Groups(4).Datasets(i).Name]))/data.session.extracellular.sr;
                    template_number = str2num(erase(info.Groups(4).Datasets(i).Name,'temp_'));
                    spikes.cluID(i) = template_number+1; %plus one since temps start with temp_0
                    spikes.total(i) = length(spikes.times{i});
                    spikes.maxWaveformCh1(i)=maxCh1(i); %preferred_electrodes(i);
                    spikes.ids{i} = spikes.cluID(i)*ones(size(spikes.times{i})); 
                end
                
                spikes.numcells = numel(spikes.times);
                spikes.UID = 1:spikes.numcells;
                % generateSpinDices
                groups = cat(1,spikes.ids{:}); % from cell to array
                [alltimes,sortidx] = sort(cat(1,spikes.times{:})); % Sorting spikes
                spikes.spindices = [alltimes groups(sortidx)];

                
                % spikes = loadSpikes(data.session,'format','spykingcircus','saveMat',false,'getWaveformsFromDat',false,'getWaveformsFromSource',false);
                data.spikes_spykingcircus = spikes;
                UI.settings.showSpykingcircus = true;
                uiresume(UI.fig);
                MsgLog(['SpyKING circus data loaded succesful: ' basename],2)
            else
                UI.settings.showSpykingcircus = false;
                UI.panel.spikesorting.showSpykingcircus.Value = 0;
            end
            
        elseif UI.panel.spikesorting.showSpykingcircus.Value == 1  && isfield(data,'spikes_spykingcircus')
            UI.settings.showSpykingcircus = true;
            uiresume(UI.fig);
        else
            UI.settings.showSpykingcircus = false;
            uiresume(UI.fig);
        end
        if UI.panel.spikesorting.spykingcircusBelowTrace.Value == 1
            UI.settings.spykingcircusBelowTrace = true;
        else
            UI.settings.spykingcircusBelowTrace = false;
        end
        initTraces
    end

    function showIntan(src,evnt) % Intan data
        
        evnt_indice = evnt.Indices(1);
        value = evnt.EditData;
        tag = src.Data{evnt_indice,2};
        if strcmp(tag,'adc')
            if value && ~isempty(UI.table.timeseriesdata.Data{evnt_indice,3}) && exist(fullfile(basepath,UI.table.timeseriesdata.Data{evnt_indice,3}),'file')
                UI.settings.intan_showAnalog = true;
                UI.fid.timeSeries.adc = fopen(fullfile(basepath,UI.table.timeseriesdata.Data{evnt_indice,3}), 'r');
                
            elseif value
                UI.table.timeseriesdata.Data{evnt_indice,1} = false;
                MsgLog('Failed to load Analog file',4);
            else
                UI.settings.intan_showAnalog = false;
                UI.table.timeseriesdata.Data{evnt_indice,1} = false;
            end
        end
        if strcmp(tag,'aux')
            if value && ~isempty(UI.table.timeseriesdata.Data{evnt_indice,3}) && exist(fullfile(basepath,UI.table.timeseriesdata.Data{evnt_indice,3}),'file')
                UI.settings.intan_showAux = true;
                UI.fid.timeSeries.aux = fopen(fullfile(basepath,UI.table.timeseriesdata.Data{evnt_indice,3}), 'r');
            elseif value
                UI.table.timeseriesdata.Data{evnt_indice,1} = false;
                UI.settings.intan_showAux = false;
                MsgLog('Failed to load aux file',4);
            else
                UI.settings.intan_showAux = false;
                UI.table.timeseriesdata.Data{evnt_indice,1} = false;
            end
        end
        if strcmp(tag,'dig')
            if value && ~isempty(UI.table.timeseriesdata.Data{evnt_indice,3}) && exist(fullfile(basepath,UI.table.timeseriesdata.Data{evnt_indice,3}),'file')
                UI.settings.intan_showDigital = true;
                UI.fid.timeSeries.dig = fopen(fullfile(basepath,UI.table.timeseriesdata.Data{evnt_indice,3}), 'r');
            elseif value == 1
                UI.table.timeseriesdata.Data{evnt_indice,1} = false;
                MsgLog('Failed to load digital file',4);
            else
                UI.settings.intan_showDigital = false;
                UI.table.timeseriesdata.Data{evnt_indice,1} = false;
            end
        end
        initTraces
        uiresume(UI.fig);
    end
    
    function editIntanMeta(~,~)
        [session1,~,statusExit] = gui_session(data.session,[],'inputs');
        if statusExit
            data.session = session1;
            initData(basepath,basename);
            initTraces;
            uiresume(UI.fig);
        end
    end
    
    function showTimeseriesBelowTrace(~,~)
        if UI.panel.timeseriesdata.showTimeseriesBelowTrace.Value == 1
            UI.settings.showTimeseriesBelowTrace = true;
        else
            UI.settings.showTimeseriesBelowTrace = false;
        end
        initTraces
        uiresume(UI.fig);
    end

    function plotTimeSeries(~,~)
        if any([UI.table.timeseries_data.Data{:,3}])
            figure,
            for i = 1:length(UI.data.detectecFiles.timeseries)
                timeserieName = UI.data.detectecFiles.timeseries{i};
                if UI.settings.timeseries.(timeserieName).show
                    plot(data.timeseries.(timeserieName).timestamps,data.timeseries.(timeserieName).data(:,UI.settings.timeseries.(timeserieName).channels)), axis tight, hold on
                end
            end
            ax = gca;
            plot([UI.t0;UI.t0],[ax.YLim(1);ax.YLim(2)],'--b');
            xlabel('Time (sec)'),
            title(UI.settings.timeseriesData)
        end
    end

    function exportPlotData(~,~)
        UI.settings.stream = false;        
        
        content.title = 'Export plot options'; % dialog title
        content.columns = 1; % 1 or 2 columns
        content.field_names = {'format','notes','show_basename','show_scalebar','show_timestamps'}; % name of the variables/fields
        content.field_title = {'Export format','Notes','Print basename and basepath','Show scalebar in figure','Print timestamp and duration'}; % Titles shown above the fields
        content.field_style = {'popupmenu','edit','checkbox','checkbox','checkbox'}; % popupmenu, edit, checkbox, radiobutton, togglebutton, listbox
        content.field_default = {'png','',true,true,true}; % default values
        content.format = {'char','char','logical','logical','logical'}; % char, numeric, logical (boolean), integer (only popupmenu)
        content.field_options = {{'Export to .png file (image)','Export to .pdf file (vector graphics)','Export figure via the export setup dialog'},'text','text','text','text'}; % options for popupmenus
        content.field_required = [true false false false false]; % field required?
        content.field_tooltip = {'Export format','Add notes to export?','Show basename?','Show scalebar?','Show timestamp?'};
        content = content_dialog(content);
        
        if ~content.continue
            return
        end
        % Adding text elements with timestamps and windows size        
        if content.output2.show_basename
            text_string1 = [' Session: ', UI.data.basename, ',   Basepath: ', UI.data.basepath];
        else
            text_string1 = '';
        end
        
        % Adding notes
        if ~isempty(content.output2.notes) && isempty(text_string1)
           text_string1 = [' Notes: ', content.output2.notes]; 
        elseif ~isempty(content.output2.notes)
            text_string1 = [text_string1,'.   Notes: ', content.output2.notes];
        end
        
        if ~isempty(text_string1)
            text(UI.plot_axis1,0,1,text_string1,'FontWeight', 'Bold','VerticalAlignment', 'top','HorizontalAlignment','left', 'color',UI.settings.primaryColor,'Units','normalized','BackgroundColor',UI.settings.textBackground)
        end
        
        if content.output2.show_timestamps
            timestring = [num2str(floor(UI.t0/3600),'%02.0f'),':',num2str(floor(UI.t0/60-floor(UI.t0/3600)*60),'%02.0f'),':',num2str(UI.t0-floor(UI.t0/60)*60,'%02.3f')];
            text_string2 = ['Start time: ', timestring, ' (', num2str(UI.t0), ' sec), Window duration: ', num2str(UI.settings.windowDuration), ' sec '];
            text(UI.plot_axis1,1,1,text_string2,'FontWeight', 'Bold','VerticalAlignment', 'top','HorizontalAlignment','right','color',UI.settings.primaryColor,'Units','normalized','BackgroundColor',UI.settings.textBackground)
        end
        
        % Adding scalebar
        if ~UI.settings.showScalebar && content.output2.show_scalebar
            plot(UI.plot_axis1,[0.005,0.005],[0.93,0.98],'-','linewidth',3,'color',UI.settings.primaryColor)
            text(UI.plot_axis1,0.01,0.955,[num2str(0.05/(UI.settings.scalingFactor)*1000,3),' mV'],'FontWeight', 'Bold','VerticalAlignment', 'middle','HorizontalAlignment','left','color',UI.settings.primaryColor,'BackgroundColor',UI.settings.textBackground)
        end
        drawnow
        
        timestamp = char(datetime('now','TimeZone','local','Format','_dd-MM-yyyy_HH.mm.ss'));
        
        if strcmp(content.output2.export_format,'Export to .png file (image)')
            full_file_name = fullfile(basepath,[basename,'_NeuroScope',timestamp, '.png']);
            if ~verLessThan('matlab','9.8') 
                exportgraphics(UI.plot_axis1,full_file_name)
            else
                set(UI.fig,'Units','Inches');
                set(UI.fig,'PaperPositionMode','Auto','PaperUnits','Inches','PaperSize',[UI.fig.Position(3), UI.fig.Position(4)],'PaperPosition',UI.fig.Position)
                saveas(UI.fig,full_file_name);
            end
            MsgLog(['The .png file was saved to: ' full_file_name],2);
            
        elseif strcmp(content.output2.export_format,'Export to .pdf file (vector graphics)')
            full_file_name = fullfile(basepath,[basename,'_NeuroScope',timestamp, '.pdf']);
            if ~verLessThan('matlab','9.8') 
                exportgraphics(UI.plot_axis1,full_file_name,'ContentType','vector')
            else
                % Renderer is set to painter (vector graphics)
                set(UI.fig,'Units','Inches','Renderer','painters');
                set(UI.fig,'PaperPositionMode','Auto','PaperUnits','Inches','PaperSize',[UI.fig.Position(3), UI.fig.Position(4)],'PaperPosition',UI.fig.Position)
                saveas(UI.fig,full_file_name);
                set(UI.fig,'Renderer','opengl');
            end
            MsgLog(['The .pdf file was saved to: ' full_file_name,],2);
            
        else % 'Export figure via the export setup dialog'
            % renderer is set to painter (vector graphics)
            set(UI.fig,'Units','Inches','Renderer','painters');
            set(UI.fig,'PaperPositionMode','Auto','PaperUnits','Inches','PaperSize',[UI.fig.Position(3), UI.fig.Position(4)],'PaperPosition',UI.fig.Position)
            exportsetupdlg(UI.fig)
        end
    end

    function createVideo(~,~)
        UI.settings.stream = false;
        
        content.title = 'Create video/animation'; % dialog title
        content.columns = 1; % 1 or 2 columns
        content.field_names = {'profile','framerate','duration','playback_speed'}; % name of the variables/fields
        content.field_title = {'Video profile','Framerate (Hz)','Duration (sec)','Playback speed'}; % Titles shown above the fields
        content.field_style = {'popupmenu','edit','edit','popupmenu'}; % popupmenu, edit, checkbox, radiobutton, togglebutton, listbox
        content.field_default = {'Uncompressed AVI',10,10,'1x'}; % default values
        content.format = {'char','numeric','numeric','char'}; % 'char', 'numeric', 'logical' (boolean), 'integer' (only popupmenu)
        content.field_options = {{'Archival','Motion JPEG AVI', 'MPEG-4','Uncompressed AVI','Save as .gif file (animation)'},'text','text',{'x/10','x/5','x/4','x/2','1x','2x','4x'}}; % options for popupmenus
        content.field_required = [true,true,true,true]; % field required?
        content.field_tooltip = {'File profile','Framerate of video (Hz)','Duration of video (sec)','Playback speed'};
        content = content_dialog(content);

        if ~content.continue
            return
        end

        parameters_video = content.output2;

        timestamp = char(datetime('now','TimeZone','local','Format','_dd-MM-yyyy_HH.mm.ss'));

        parameters_video.full_file_name = fullfile(basepath,[basename,'_NeuroScope',timestamp]);

        streamData_to_video(parameters_video)

        MsgLog(['The video was saved to: ' parameters_video.full_file_name],2);
    end
    
    function setTimeSeriesBoundary(~,~)
        UI.settings.timeseries.lowerBoundary = str2num(UI.panel.timeseries.lowerBoundary.String);
        UI.settings.timeseries.upperBoundary = str2num(UI.panel.timeseries.upperBoundary.String);
        if isempty(UI.settings.timeseries.lowerBoundary)
            UI.settings.timeseries.lowerBoundary = 0;
        end
        if isempty(UI.settings.timeseries.upperBoundary)
            UI.settings.timeseries.upperBoundary = 40;
        end
        UI.panel.timeseries.upperBoundary.String = num2str(UI.settings.timeseries.upperBoundary);
        UI.panel.timeseries.lowerBoundary.String = num2str(UI.settings.timeseries.lowerBoundary);
        uiresume(UI.fig);
    end
    
    function changeColormap(~,~)
        colormapList = {'lines','hsv','jet','colorcube','prism','parula','hot','cool','spring','summer','autumn','winter','gray','bone','copper','pink','white'};
        initial_colormap = UI.settings.colormap;
        color_idx = find(strcmp(UI.settings.colormap,colormapList));
        
        colormap_dialog = dialog('Position', [0, 0, 300, 350],'Name','Change colormap of ephys traces','visible','off'); movegui(colormap_dialog,'center'), set(colormap_dialog,'visible','on')
        colormap_uicontrol = uicontrol('Parent',colormap_dialog,'Style', 'ListBox', 'String', colormapList, 'Position', [10, 50, 280, 270],'Value',color_idx,'Max',1,'Min',1,'Callback',@(src,evnt)previewColormap);
        uicontrol('Parent',colormap_dialog,'Style','pushbutton','Position',[10, 10, 135, 30],'String','OK','Callback',@(src,evnt)close_dialog);
        uicontrol('Parent',colormap_dialog,'Style','pushbutton','Position',[155, 10, 135, 30],'String','Cancel','Callback',@(src,evnt)cancel_dialog);
        uicontrol('Parent',colormap_dialog,'Style', 'text', 'String', 'Colormaps', 'Position', [10, 320, 280, 20],'HorizontalAlignment','left');
        uicontrol(colormap_uicontrol)
        uiwait(colormap_dialog);

        % [idx,~] = listdlg('PromptString','Select colormap','ListString',colormapList,'ListSize',[250,400],'InitialValue',temp,'SelectionMode','single','Name','Colormap','Callback',@previewColormap);
        function close_dialog
            idx = colormap_uicontrol.Value;
            
            UI.settings.colormap = colormapList{idx};
            
            % Generating colormap
            UI.colors = eval([UI.settings.colormap,'(',num2str(data.session.extracellular.nElectrodeGroups),')']);
            updateChanCoordsColorHighlight
            
            % Updating table colors
            classColorsHex = rgb2hex(UI.colors);
            classColorsHex = cellstr(classColorsHex(:,2:end));
            UI.table.electrodeGroups.Data(:,2) = strcat('<html><BODY bgcolor="',classColorsHex','">&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;</BODY></html>');
            delete(colormap_dialog);
            uiresume(UI.fig);
            
        end
        function cancel_dialog
            % Closes dialog
            UI.settings.colormap = initial_colormap;
            UI.colors = eval([UI.settings.colormap,'(',num2str(data.session.extracellular.nElectrodeGroups),')']);
            updateChanCoordsColorHighlight
            plotData;
            delete(colormap_dialog);
        end
        
        function previewColormap
            % Previewing colormap
            idx = colormap_uicontrol.Value;
            if ~isempty(idx)
                UI.settings.colormap = colormapList{idx};
                UI.colors = eval([UI.settings.colormap,'(',num2str(data.session.extracellular.nElectrodeGroups),')']);
                updateChanCoordsColorHighlight
                plotData;
            end
        end
    end

    function changeLinewidth(~,~)
        prompt = {'Linewidth (range: 0.5-5)'};
        dlgtitle = 'Linewidth';
        definput = {num2str(UI.settings.linewidth)};
        dims = [1 40];
        opts.Interpreter = 'tex';
        answer = inputdlg(prompt,dlgtitle,dims,definput,opts);
        if ~isempty(answer)
            numeric_answer = str2num(answer{1});
            if ~isempty(answer{1}) && numeric_answer >= 0.5 && numeric_answer <= 5
                UI.settings.linewidth = numeric_answer;
            end
        end        
        uiresume(UI.fig);
    end
    
    function changeSpikesColormap(~,~)
        colormapList = {'lines','hsv','jet','colorcube','prism','parula','hot','cool','spring','summer','autumn','winter','gray','bone','copper','pink','white'};
        initial_colormap = UI.settings.spikesColormap;
        color_idx = find(strcmp(UI.settings.spikesColormap,colormapList));
        
        colormap_dialog = dialog('Position', [0, 0, 300, 350],'Name','Change colormap of spikes','visible','off'); movegui(colormap_dialog,'center'), set(colormap_dialog,'visible','on')
        colormap_uicontrol = uicontrol('Parent',colormap_dialog,'Style', 'ListBox', 'String', colormapList, 'Position', [10, 50, 280, 270],'Value',color_idx,'Max',1,'Min',1,'Callback',@(src,evnt)previewColormap);
        uicontrol('Parent',colormap_dialog,'Style','pushbutton','Position',[10, 10, 135, 30],'String','OK','Callback',@(src,evnt)close_dialog);
        uicontrol('Parent',colormap_dialog,'Style','pushbutton','Position',[155, 10, 135, 30],'String','Cancel','Callback',@(src,evnt)cancel_dialog);
        uicontrol('Parent',colormap_dialog,'Style', 'text', 'String', 'Colormaps', 'Position', [10, 320, 280, 20],'HorizontalAlignment','left');
        uicontrol(colormap_uicontrol)
        uiwait(colormap_dialog);

        function close_dialog
            UI.settings.spikesColormap = colormapList{colormap_uicontrol.Value};
            delete(colormap_dialog);
            uiresume(UI.fig);
            
        end
        function cancel_dialog
            % Closes dialog
            UI.settings.spikesColormap = initial_colormap;
            plotData;
            delete(colormap_dialog);
        end
        
        function previewColormap
            % Previewing colormap
            color_idx = colormap_uicontrol.Value;
            if ~isempty(color_idx)                
                UI.settings.spikesColormap = colormapList{color_idx};
                plotData;
            end
        end
    end
    
    function setColorGroups(src,~)
        UI.menu.display.colorgroups.option(1).Checked = 'off';
        UI.menu.display.colorgroups.option(2).Checked = 'off';
        UI.menu.display.colorgroups.option(3).Checked = 'off';

        if src.Position == 1
            UI.menu.display.colorgroups.option(1).Checked = 'on';
            UI.settings.colorByChannels = 1;
            
        elseif src.Position == 2
            prompt = {'Number of color groups (1-50)'};
            dlgtitle = 'Color groups';
            definput = {num2str(UI.settings.nColorGroups)};
            dims = [1 40];
            opts.Interpreter = 'tex';
            answer = inputdlg(prompt,dlgtitle,dims,definput,opts);
            if ~isempty(answer)
                numeric_answer = str2num(answer{1});
                if ~isempty(answer{1}) && rem(numeric_answer,1)==0 && numeric_answer > 0 && numeric_answer <= 50
                    UI.settings.nColorGroups = numeric_answer;
                end
                UI.menu.display.colorgroups.option(src.Position).Checked = 'on';
                UI.settings.colorByChannels = 2;
            end
        
        elseif src.Position == 3
            prompt = {'Number of channels per group (1-50)'};
            dlgtitle = 'Color groups';
            definput = {num2str(UI.settings.nColorGroups)};
            dims = [1 40];
            opts.Interpreter = 'tex';
            answer = inputdlg(prompt,dlgtitle,dims,definput,opts);
            if ~isempty(answer)
                numeric_answer = str2num(answer{1});
                if ~isempty(answer{1}) && rem(numeric_answer,1)==0 && numeric_answer > 0 && numeric_answer <= 50
                    UI.settings.nColorGroups = numeric_answer;
                end
                UI.menu.display.colorgroups.option(src.Position).Checked = 'on';
                UI.settings.colorByChannels = 3;
            end
        end
        UI.menu.display.colorgroups.option(UI.settings.colorByChannels).Checked = 'on';
        uiresume(UI.fig);
    end
    
    function columnTraces(~,~)
        UI.settings.plotTracesInColumns = ~UI.settings.plotTracesInColumns;
        if UI.settings.plotTracesInColumns
            UI.menu.display.plotTracesInColumns.Checked = 'on';
        else
            UI.menu.display.plotTracesInColumns.Checked = 'off';
        end
        initTraces;
        uiresume(UI.fig);
    end

    function changeBackgroundColor(~,~)
            backgroundColor = userSetColor(UI.plot_axis1.Color,'Background color');
            primaryColor = userSetColor(UI.plot_axis1.XColor,'Primary color (ticks, text, and rasters)');
            
            UI.settings.background = backgroundColor;
            UI.settings.textBackground = [backgroundColor,0.7];
            UI.settings.primaryColor = primaryColor;
            UI.plot_axis1.XColor = UI.settings.primaryColor;
            UI.plot_axis1.Color = UI.settings.background;
            uiresume(UI.fig);
    end
    
    function colorpick_out = userSetColor(colorpick1,title1)
        if verLessThan('matlab','9.9') 
            try
                colorpick_out = uisetcolor(colorpick1,title1);
            catch
                MsgLog('Colorpick faield',4)
            end
        else
            colorpick_out = uicolorpicker(colorpick1,title1);
        end
    end
    
    function setTimeText(t0)
        timestring = [num2str(floor(t0/3600),'%02.0f'),':',num2str(floor(t0/60-floor(t0/3600)*60),'%02.0f'),':',num2str(t0-floor(t0/60)*60,'%02.3f')];
        UI.elements.lower.timeText.String = ['Time (s) ', timestring];
    end
    
    function toggleDebug(~,~)
        UI.settings.debug = ~UI.settings.debug;
        if UI.settings.debug
            UI.menu.display.debug.Checked = 'on';
        else
            UI.menu.display.debug.Checked = 'off';
        end
        uiresume(UI.fig);
    end
    
    function loadFromFolder(~,~)
        % Shows a file dialog allowing you to select session via a .dat/.mat/.xml to load
        UI.settings.stream = false;
        path1 = uigetdir(pwd,'Please select the data folder');
        if ~isequal(path1,0)
            basename = basenameFromBasepath(path1);
            data = [];
            basepath = path1;
            initData(basepath,basename);
            initTraces;
            uiresume(UI.fig);
        end
    end
    
    function loadFromFile(~,~)
        UI.settings.stream = false;
        % Shows a file dialog allowing you to select session via a .dat/.mat/.xml to load
        [file,path] = uigetfile('*.mat;*.dat;*.lfp;*.xml','Please select any file with the basename in it');
        if ~isequal(file,0)
            temp = strsplit(file,'.');
            data = [];
            basepath = path;
            basename = temp{1};
            UI.priority = temp{2};
            initData(basepath,basename);
            initTraces;
            uiresume(UI.fig);
        end
    end
    
    function loadFromRecentFiles(src,~)
        UI.settings.stream = false;
        [basepath1,basename1,~] = fileparts(src.Text);
        if exist(basepath1,'dir')
            data = [];
            basepath = basepath1;
            basename = basename1;
            initData(basepath,basename);
            initTraces;
            uiresume(UI.fig);
        else
            MsgLog(['Basepath does not exist: ' basepath1],4)
        end
    end
    
    function openWebsite(src,~)
        % Opens the CellExplorer website in your browser
        if isprop(src,'Text')
            source = src.Text;
        else
            source = '';
        end
        switch source
            case '- About NeuroScope2'
                web('https://cellexplorer.org/interface/neuroscope2/','-new','-browser')
            case '- Tutorial on metadata'
                web('https://cellexplorer.org/tutorials/metadata-tutorial/','-new','-browser')
            case '- Documentation on session metadata'
                web('https://cellexplorer.org/datastructure/data-structure-and-format/#session-metadata','-new','-browser')
            case 'Support'
                 web('https://cellexplorer.org/#support','-new','-browser')
            case '- Report an issue'
                web('https://github.com/petersenpeter/CellExplorer/issues/new?assignees=&labels=bug&template=bug_report.md&title=','-new','-browser')
            case '- Submit feature request'
                web('https://github.com/petersenpeter/CellExplorer/issues/new?assignees=&labels=enhancement&template=feature_request.md&title=','-new','-browser')
            otherwise
                web('https://cellexplorer.org/','-new','-browser')
        end
    end

    function MsgLog(message,priority)
        % Writes the input message to the message log with a timestamp. The second parameter
        % defines the priority i.e. if any  message or warning should be given as well.
        % priority:
        % 1: Show message in Command Window
        % 2: Show msg dialog
        % 3: Show warning in Command Window
        % 4: Show warning dialog
        % -1: disp only
        UI.settings.stream = false;
        timestamp = datetime('now','TimeZone','local','Format','dd-MM-yyyy HH:mm:ss');
        message2 = sprintf('[%s] %s', timestamp, message);
        %         if ~exist('priority','var') || (exist('priority','var') && any(priority >= 0))
        %             UI.popupmenu.log.String = [UI.popupmenu.log.String;message2];
        %             UI.popupmenu.log.Value = length(UI.popupmenu.log.String);
        %         end
        try
            if exist('priority','var')
                dialog1.Interpreter = 'none';
                dialog1.WindowStyle = 'modal';
                if any(priority < 0)
                    disp(message2)
                end
                if any(priority == 1)
                    disp(message)
                end
                if any(priority == 2)
                    if UI.settings.allow_dialogs
                        msgbox(message,'NeuroScope2',dialog1);
                    else
                        disp(message)
                    end
                end
                if any(priority == 3)
                    warning(message)
                end
                if any(priority == 4)
                    if UI.settings.allow_dialogs
                        warndlg(message,'NeuroScope2')
                    else
                        warning(message)
                    end
                end
            end
        end
    end
end
