function outputPath = dat2mef(signal, outputPath, channelNames, ...
        samplingFrequency, startUutc, options)
%DAT2MEF Write a multichannel signal as a MEF 3.0 session using mef3io.
%
% outputPath = dat2mef(signal, outputPath, channelNames, ...
%     samplingFrequency, startUutc)
%
% outputPath = dat2mef(..., Overwrite=true, Units="uV", Precision=4)
%
% INPUTS
%   signal              Samples-by-channels numeric matrix in physical units.
%   outputPath          Output MEF session path. BIDS-compatible MEF3 sessions
%                       conventionally use the .mefd extension.
%   channelNames        One unique name per signal column.
%   samplingFrequency   Sampling frequency in Hz.
%   startUutc           Recording start time in microseconds since Unix epoch.
%
% OPTIONS
%   Overwrite           Replace an existing MEF session. Default false.
%   Units               Physical unit per channel. Scalar values are expanded to all channels. Default "uV".
%   Precision           MEF precision supplied to Writer.write. Default 4.
%
% DEPENDENCY
%   mef3io MATLAB package: https://bnelair.github.io/mef3io/
%
% This function is intentionally independent from BCI2000_data. It only
% knows how to write an already prepared signal to MEF3. This allows the
% class to dispatch other extensions to future dat2edf or dat2brainvision
% functions without introducing format-specific code into BCI2000_data.

    arguments
        signal {mustBeNumeric, mustBeNonempty}
        outputPath (1,1) string
        channelNames (:,1) string
        samplingFrequency (1,1) double {mustBePositive, mustBeFinite}
        startUutc (1,1) {mustBeNumeric, mustBeFinite}
        options.Overwrite (1,1) logical = false
        options.Units string = "uV"
        options.Precision (1,1) double {mustBePositive, mustBeFinite} = 4
    end

    if isempty(which("mef3io.Writer"))
        error("dat2mef:MissingMEF3IO", ...
            ["mef3io.Writer was not found on the MATLAB path. Install the " ...
             "mef3io MATLAB package and add its matlab directory to the path."]);
    end

    [~, ~, extension] = fileparts(outputPath);
    if ~strcmpi(extension, ".mefd")
        error("dat2mef:InvalidExtension", ...
            "MEF3 output must use the .mefd extension.");
    end

    nChannels = size(signal, 2);
    if numel(channelNames) ~= nChannels
        error("dat2mef:ChannelCountMismatch", ...
            ["The number of channel names (%d) does not match the number " ...
             "of signal columns (%d)."], numel(channelNames), nChannels);
    end

    if any(ismissing(channelNames) | strlength(channelNames) == 0)
        error("dat2mef:InvalidChannelNames", ...
            "All MEF channels must have non-empty names.");
    end

    if numel(unique(channelNames)) ~= nChannels
        error('dat2mef:DuplicateChannelNames', ...
            'MEF channel names must be unique.');
    end

    if ~options.Overwrite && isfolder(outputPath)
        error('dat2mef:OutputExists', ...
            'The output MEF session already exists. Set Overwrite=true to replace it: %s', ...
            outputPath);
    end

    units = string(options.Units(:));
    if isscalar(units)
        units = repmat(units, nChannels, 1);
    elseif numel(units) ~= nChannels
        error('dat2mef:UnitCountMismatch', ...
            'The number of unit labels (%d) does not match the number of signal columns (%d).', ...
            numel(units), nChannels);
    end

    units(ismissing(units) | strlength(units) == 0) = "n/a";
    startUutc = int64(startUutc);

    % mef3io.Writer accepts Units when a writer is opened. To preserve a
    % distinct unit for each MEF channel, open the session for each channel
    % with that channel's unit. The first writer creates/overwrites the
    % session; subsequent writers reopen the existing session and add the
    % next channel.
    for channelIndex = 1:nChannels
        overwriteThisOpen = options.Overwrite && channelIndex == 1;

        writer = mef3io.Writer(outputPath, ...
            Overwrite=overwriteThisOpen, ...
            Units=units(channelIndex));
        writerCleanup = onCleanup(@() delete(writer)); %#ok<NASGU>

        writer.write( ...
            channelNames(channelIndex), ...
            signal(:, channelIndex), ...
            startUutc, ...
            samplingFrequency, ...
            Precision=options.Precision);

        delete(writer);
        clear writerCleanup writer
    end
end
