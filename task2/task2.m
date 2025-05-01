function gnssMask = calculateSkyMask()
    % Calculate GNSS sky mask and estimate positions
    % 
    % Output:
    %   gnssMask - Struct containing sky mask and positioning results

    %% Initialization and Configuration
    % Define reference location 
    REF_LATITUDE = 22.3198722;  
    REF_LONGITUDE = 114.209101777778;  
    REF_ALTITUDE = 3.0;          % meters
    LIGHT_SPEED = 299792458;     % m/s
    ELEVATION_BUFFER = 25;       % degrees
    
    % Define data paths (NOTE: Update these paths for your system)
    MASK_DATA_PATH = fullfile('skymask_A1_urban.csv');
    NAV_DATA_PATH = fullfile('navSolutionResults.mat');
    

    %% Load Navigation Data
    gnssMask = struct();
    
    % Load satellite navigation solutions
    if ~exist(NAV_DATA_PATH, 'file')
        error('Navigation data file not found: %s', NAV_DATA_PATH);
    end
    
    navData = load(NAV_DATA_PATH);  
    gnssMask.pseudoranges = navData.navSolutions.correctedP;
    gnssMask.azimuths = navData.navSolutions.az;
    gnssMask.elevations = navData.navSolutions.el;
    gnssMask.satellitePositions = navData.navSolutions.satPositions;
    
    disp('Loaded Data Dimensions:');
    disp(['Pseudoranges:   ', num2str(size(gnssMask.pseudoranges))]);
    disp(['Azimuths:       ', num2str(size(gnssMask.azimuths))]);
    disp(['Elevations:     ', num2str(size(gnssMask.elevations))]);
    disp(['Sat Positions:  ', num2str(size(gnssMask.satellitePositions))]);

    %% Process Sky Mask Data
    % Read and process sky mask from CSV file
    maskData = readmatrix(MASK_DATA_PATH);
    gnssMask.maskAzimuth = maskData(:,1);
    gnssMask.maskElevation = maskData(:,2);
    
    % Create elevation vector with 1-degree azimuth resolution
    elevationVector = nan(361, 1);
    for i = 1:numel(gnssMask.maskAzimuth)
        azIndex = round(mod(gnssMask.maskAzimuth(i), 360));
        elevationVector(azIndex + 1) = gnssMask.maskElevation(i);
    end
    
    % Interpolate missing values
    validIndices = find(~isnan(elevationVector));
    gnssMask.maskElevationVector = interp1(...
        validIndices - 1, ...
        elevationVector(validIndices), ...
        (0:360)', 'linear', 'extrap');
    
    % Plot sky mask
    plotSkyMask(gnssMask.maskElevationVector);
    
    % Apply elevation buffer
    gnssMask.maskRelative = max(0, gnssMask.maskElevationVector - ELEVATION_BUFFER);

    %% Positioning Calculation Setup
    % Initialize WGS84 ellipsoid parameters
    gnssMask.wgs84 = wgs84Ellipsoid('meters');
    
    % Convert reference position to ECEF coordinates
    [refX, refY, refZ] = geodetic2ecef(...
        gnssMask.wgs84, ...
        REF_LATITUDE, ...
        REF_LONGITUDE, ...
        REF_ALTITUDE);
    
    % Initialize variables for positioning solution
    clockBias = 0;  % Initial clock bias estimate
    [numSatellites, numEpochs] = size(gnssMask.pseudoranges);   
    positionSolutions = nan(numEpochs, 4);  % [X, Y, Z, clock]
    visibleCounts = zeros(numEpochs, 1);
    convergenceTolerance = 1e-4;

    %% Main Processing Loop
    for epoch = 1:numEpochs
        % Extract current epoch data
        currentData = struct();
        currentData.pseudoranges = gnssMask.pseudoranges(:, epoch);
        currentData.azimuths = gnssMask.azimuths(:, epoch);
        currentData.elevations = gnssMask.elevations(:, epoch);
        currentData.satPositions = squeeze(gnssMask.satellitePositions(:,:,epoch))';
        
        % Determine which satellites are visible (considering sky mask)
        [visibleSatellites, weights] = getVisibleSatellites(...
            currentData, ...
            gnssMask.maskRelative);
        
        visibleCounts(epoch) = numel(visibleSatellites);
        fprintf('Epoch %d: %d visible satellites\n', epoch, visibleCounts(epoch));
        
        % Skip this epoch if insufficient visible satellites
        if visibleCounts(epoch) < 4
            continue;
        end
        
        % Solve for position using weighted least squares
        estPosition = [refX; refY; refZ; clockBias];
        currentSolution = solvePosition(...
            currentData, ...
            visibleSatellites, ...
            weights, ...
            estPosition, ...
            LIGHT_SPEED, ...
            convergenceTolerance);
        
        % Store solution and update reference for next epoch
        positionSolutions(epoch,:) = currentSolution';
        refX = currentSolution(1);
        refY = currentSolution(2);
        refZ = currentSolution(3);
        clockBias = currentSolution(4);
    end

    %% Results Analysis and Output
    analyzeResults(...
        positionSolutions, ...
        visibleCounts, ...
        gnssMask.wgs84, ...
        REF_LATITUDE, ...
        REF_LONGITUDE);
end

%% Helper Functions

function plotSkyMask(elevationVector)
    % Plot the sky mask elevation profile
    figure;
    plot(0:360, elevationVector, 'LineWidth', 1.5);
    xlabel('Azimuth (°)');
    ylabel('Blocking Elevation (°)');
    title('Sky Mask Horizon Profile');
    grid on;
    ylim([0 90]);
end

function [visibleSats, weights] = getVisibleSatellites(data, maskRelative)
    % Determine which satellites are visible given the sky mask
    numSats = numel(data.pseudoranges);
    visibleSats = false(numSats, 1);
    weights = zeros(numSats, 1);
    
    for sat = 1:numSats
        azIndex = floor(mod(data.azimuths(sat), 360)) + 1;
        minElevation = maskRelative(azIndex);
        
        if data.elevations(sat) > minElevation
            % Weight based on elevation above mask
            elevationDifference = data.elevations(sat) - minElevation;
            weights(sat) = sin(deg2rad(elevationDifference)) * sin(deg2rad(data.elevations(sat)));
            visibleSats(sat) = true;
        end
    end
    
    visibleSats = find(visibleSats);  % Return indices of visible satellites
end

function solution = solvePosition(data, visibleSats, weights, initialGuess, lightSpeed, tolerance)
    % Solve for position using weighted least squares
    
    solution = initialGuess;
    
    for iteration = 1:10
        numVisible = numel(visibleSats);
        designMatrix = zeros(numVisible, 4);
        residuals = zeros(numVisible, 1);
        weightMatrix = diag(weights(visibleSats));
        
        for i = 1:numVisible
            satIdx = visibleSats(i);
            predictedRange = norm(data.satPositions(satIdx,:)' - solution(1:3));
            predictedPseudorange = predictedRange + lightSpeed * solution(4);
            
            residuals(i) = data.pseudoranges(satIdx) - predictedPseudorange;
            
            lineOfSight = (solution(1:3) - data.satPositions(satIdx,:)') / predictedRange;
            designMatrix(i,1:3) = lineOfSight';
            designMatrix(i,4) = -lightSpeed;
        end
        
        % Solve for position update
        correction = (designMatrix' * weightMatrix * designMatrix) \ ...
                    (designMatrix' * weightMatrix * residuals);
        
        solution = solution + correction;
        
        % Check for convergence
        if norm(correction) < tolerance
            break;
        end
    end
end

function analyzeResults(solutions, visibleCounts, referenceEllipsoid, refLat, refLon)
    % Analyze and plot the positioning results
    
    fprintf('Visible satellites per epoch (min/max): %d / %d\n', ...
        min(visibleCounts), max(visibleCounts));
    
    % Check if we need to relax the mask
    if max(visibleCounts) < 4
        warning('All epochs have <4 visible satellites. Consider relaxing the sky mask.');
    end
    
    % Convert valid solutions to geodetic coordinates
    validSolutions = solutions(~any(isnan(solutions), 2), :);
    if isempty(validSolutions)
        disp('No valid solutions obtained.');
        return;
    end
    
    [latitudes, longitudes, ~] = ecef2geodetic(...
        referenceEllipsoid, ...
        validSolutions(:,1), ...
        validSolutions(:,2), ...
        validSolutions(:,3));
    
    % Plot results
    figure;
    plot(longitudes, latitudes, 'r.', 'MarkerSize', 10); % Estimated positions
    hold on;
    plot(refLon, refLat, 'bx', 'MarkerSize', 10); % Reference position
    xlabel('Longitude (°)');
    ylabel('Latitude (°)');
    legend('Estimated Positions', 'Reference Location');
    title('GNSS Positioning with Sky Mask');
    grid on;
end
