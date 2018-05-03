function [varargout] = blr_mtl_mkl_test(hyp, X, t, nTasks, nDimsPerTask, extraKernels, xs)

% Bayesian linear regression: multi-task learning (MTL) version
%
% This version uses the Cholesky Decomposition based approach to inverting
% matrices
%
% ***************************************
% Assumed covariance prior structure: 
%
%    1/alpha * kron(gamma * eye(nTasks) + (1 - gamma) * ones(nTasks)), eye(nDims))  
%
% where: alpha > 0,  0 < gamma < 1
% ***************************************
%
% Fits a bayesian linear regression model, where the inputs are:
%    hyp : vector of hyperparmaters. hyp = [log(beta); log(alpha); logit(gamma)]
%    X   : N     x (nTasks * nDims)  data matrix
%    t   : N     x 1                 vector of targets across all tasks
%    xs  : Ntest x (nTasks * nDims)  matrix of test cases
% 
%  where N = sum(N_i), N_i is number of targets per task
%
% The hyperparameter beta is the noise precision and alpha is the precision
% over lengthscale parameters. This can be either a scalar variable (a
% common lengthscale for all input variables), or a vector of length D (a
% different lengthscale for each input variable, derived using an automatic
% relevance determination formulation).
%
% Two modes are supported: 
%    [nlZ, dnlZ, post] = blr(hyp, x, y);  % report evidence and derivatives
%    [mu, s2, post]    = blr(hyp, x, y, xs); % predictive mean and variance
%
% Written by A. Marquand
% Updated by L. Aksman for new parameterization of prior covariance that enables multi-task + multi-kernel learning

if nargin<6 || nargin>7
    disp('Usage: [nlZ dnlZ] = blr_mtl_mkl_flex(hyp, X, t, nTasks, nDimsPerTask, extraKernels);')
    disp('   or: [mu  s2  ] = blr_mtl_mkl_flex(hyp, X, t, nTasks, nDimsPerTask, extraKernels, xs);')
    return
end

%assert(length(hyp) == 3);
n_extra_kernels     = length(extraKernels);
assert(length(hyp) == (2 + nTasks + n_extra_kernels));

[N, D]              = size(X);

assert(D == nTasks * nDimsPerTask);


beta                = exp(hyp(1));           % noise precision

alpha1s             = exp(hyp( 1  + (1:nTasks)));
alpha2              = exp(hyp( 2  + nTasks));
alphaExtras         = exp(hyp((2  + nTasks + 1):end));

couplingMat         = diag(alpha1s) + (alpha2/nTasks) * ones(nTasks);
for i = 1:n_extra_kernels
    couplingMat     = couplingMat + alphaExtras(1) * extraKernels(i).mat;
end

Sigma               = kron(couplingMat, eye(nDimsPerTask));
cholSigma        	= chol(Sigma); %** upper triagle


%*********** alpha1s
[dSigmas, dHypers]  = deal({});

for i = 1:nTasks
    v_i             = zeros(nTasks, 1);
    v_i(i)          = 1;
    
    dSigmas{end+1} 	= kron(v_i * v_i', eye(nDimsPerTask));
    dHypers{end+1} 	= alpha1s(i);
end

%*********** alpha2
dSigmas{end+1}     	= kron((1/nTasks) * ones(nTasks), eye(nDimsPerTask));
dHypers{end+1}     	= alpha2;

%********** extra kernels
for i = 1:n_extra_kernels
    dSigmas{end+1} 	= kron(extraKernels(i).mat, eye(nDimsPerTask));
    dHypers{end+1}  = alphaExtras(i);
end


%********************************

% useful quantities
XX                  = X'*X;

%A                   = beta*XX + invSigma;           % posterior precision
v                   = X * Sigma;
chol_temp           = chol((1/beta) * eye(N) + v*X');
invA                = Sigma - v' * solve_chol(chol_temp, v);

S                   = invA;
Q                   = S*X';
m                   = beta*Q*t;               % posterior mean

% compute like this for to avoid numerical overflow
logdetSigma         = 2*sum(log(diag(cholSigma)));   
logdetA             = -logdetSigma + N*log(beta) + 2*sum(log(diag(chol_temp))); %2*sum(log(diag(cholA)));         
 

if nargin == 6

    invSigma_m      = solve_chol(cholSigma, m);
    
    nlZ_const       = D*log(2*pi); %N*log(2*pi);
    
    nlZ             = -0.5*( N*log(beta) - nlZ_const - logdetSigma ...
                      - beta*(t-X*m)'*(t-X*m) - m'* invSigma_m - ...
                      logdetA );

    if nargout > 1    % derivatives?
        dnlZ        = zeros(size(hyp));
        b           = (eye(D) - beta*Q*X)*Q*t;
        
        % repeatedly computed quantities for derivatives
        Xt          = X'*t;
        XXm         = XX*m;
        
        %SXt         = S*Xt;
        SXt         = invA * Xt;
        
        % noise precision
        dnlZ(1)     = -( N/(2*beta) - 0.5*(t'*t) + t'*X*m + beta*t'*X*b - 0.5*m'*XXm ...
                      - beta*b'*XXm - b'*invSigma_m -0.5*trace(Q*X) )*beta;
                  
        % variance parameters
        for i = 1:length(dSigmas)
            
            dSigma 	= dSigmas{i};
            dHyper 	= dHypers{i};
                        
           
            invSigma_dSigma  	=  solve_chol(cholSigma, dSigma);
            F                   = -solve_chol(cholSigma, invSigma_dSigma')';
            
            c    	= -beta*S*F*SXt;
            
            dnlZ(i+1) = -( -0.5*trace(invSigma_dSigma) + ...
                           beta*Xt'*c - beta*c'*XXm - c'*invSigma_m - ...
                           0.5*m'*F*m - 0.5*trace(invA * F) ) * dHyper;            
            
        end   
        
        post.m      = m;
        post.invA   = invA;
    end
    if nargout > 1
        varargout   = {nlZ, dnlZ, post};
    else
        varargout   = {nlZ};
    end
    
else % prediction mode
      
    ys              = xs*m;
    s2              = 1/beta + diag(xs*(invA * xs'));
    post.m          = m;
    post.invA       = invA;
    varargout       = {ys, s2, post};
end

end