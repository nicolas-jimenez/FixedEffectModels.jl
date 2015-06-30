##############################################################################
##
## VcovData (and its children) has four important methods: 
## residuals
## regressors
## invcrossmatrix (by default (X'X)^{-1})
## number of obs
## degree of freedom
## Parametrized by whether residuals is vector (as usual) or matrix (used for weak identification test in iv)
##############################################################################

immutable type VcovData{N} 
	invcrossmatrix::Matrix{Float64} 
	regressors::Matrix{Float64} 
	residuals::Array{Float64, N}
	df_residual::Int64
	function VcovData(invcrossmatrix::Matrix{Float64}, regressors::Matrix{Float64}, residuals::Array{Float64, N}, 	df_residual::Int64)
		size(regressors, 1) == size(residuals, 1) || error("regressors and residuals should have same  number of rows")
		size(invcrossmatrix, 1) == size(invcrossmatrix, 2) || error("invcrossmatrix is a square matrix")
		size(invcrossmatrix, 1) == (size(regressors, 2) * size(residuals, 2))  || error("invcrossmatrix should be square matrix of dimension size(regressors, 2) x size(residuals, 2)")
		new(invcrossmatrix, regressors, residuals, df_residual)
	end
end
residuals(x::VcovData) = x.residuals
regressors(x::VcovData) = x.regressors
invcrossmatrix(x::VcovData) = x.invcrossmatrix
df_residual(x::VcovData) = x.df_residual
nobs(x::VcovData) = size(regressors(x), 1)


typealias VcovDataVector VcovData{1} 
typealias VcovDataMatrix VcovData{2} 


# convert a linear model into VcovData
function VcovData(x::LinearModel) 
	VcovData(inv(cholfact(x)), x.pp.X, residuals(x), size(x.pp.X, 1))
end


##############################################################################
##
## AbstractVcovMethod (and its children) has two methods: 
## allvars that returns variables needed in the dataframe
## shat!, that returns a covariance matrix. It may change regressors in place, (but not invcrossmatrix).
##
##############################################################################

abstract AbstractVcovMethod
allvars(x::AbstractVcovMethod) = nothing
abstract AbstractVcovMethodData


# These default methods will be called for errors that do not require access to variables from the initial dataframe (like simple and White standard errors)


#
# simple standard errors
#

immutable type VcovSimple <: AbstractVcovMethod end
immutable type VcovSimpleData <: AbstractVcovMethodData end
VcovMethodData(v::VcovSimple, df::AbstractDataFrame) = VcovSimpleData()
function vcov!(v::VcovSimpleData, x::VcovData)
 	scale!(invcrossmatrix(x), abs2(norm(residuals(x), 2)) /  df_residual(x))
end
function shat!(v::VcovSimpleData, x::VcovData)
 	scale(inv(invcrossmatrix(x)), abs2(norm(residuals(x), 2)))
end


#
# White standard errors
#

immutable type VcovWhite <: AbstractVcovMethod end
immutable type VcovWhiteData <: AbstractVcovMethodData end
VcovMethodData(v::VcovWhite, df::AbstractDataFrame) = VcovWhiteData()
function vcov!(v::VcovWhiteData, x::VcovData) 
	S = shat!(v, x)
	scale!(S, nobs(x)/df_residual(x))
	sandwich(invcrossmatrix(x), S) 
end

function shat!(v::VcovWhiteData, x::VcovData{1}) 
	X = regressors(x)
	res = residuals(x)
	Xu = broadcast!(*, X, X, res)
	S = At_mul_B(Xu, Xu)
end

function shat!(t::VcovWhiteData, x::VcovData{2}) 
	X = regressors(x)
	res = residuals(x)
	dim = size(X, 2) * size(res, 2)
	S = fill(zero(Float64), (dim, dim))
	temp = similar(S)
	kronv = fill(zero(Float64), dim)
	@inbounds for i in 1:nobs(x)
		j = 0
		for l in 1:size(res, 2)
			for k in 1:size(X, 2)
				j += 1
				kronv[j] = X[i, k] * res[i, l]
			end
		end
		temp = A_mul_Bt!(temp, kronv, kronv)
		S += temp
	end
	return(S)
end


function sandwich(H::Matrix{Float64}, S::Matrix{Float64})
	H * S * H
end



#
# Clustered standard errors
#

immutable type VcovCluster  <: AbstractVcovMethod
	clusters::Vector{Symbol}
end
VcovCluster(x::Symbol) = VcovCluster([x])
allvars(x::VcovCluster) = x.clusters

immutable type VcovClusterData <: AbstractVcovMethodData
	clusters::DataFrame
	size::Dict{Symbol, Int64}
end

function VcovMethodData(v::VcovCluster, df::AbstractDataFrame) 
	vclusters = DataFrame(Vector, size(df, 1), length(v.clusters))
	names!(vclusters, v.clusters)
	vsize = Dict{Symbol, Int64}()
	for c in v.clusters
		p = df[c]
		typeof(p) <: PooledDataArray || error("Cluster variable $(c) is of type $(typeof(p)), but should be a PooledDataArray.")
		vclusters[c] = p
		# may be subset / NA
		vsize[c] = length(unique(p.refs))
	end
	VcovClusterData(vclusters, vsize)
end

function vcov!(v::VcovClusterData, x::VcovData)
	S = shat!(v, x)
	scale!(S, (nobs(x)-1) / df_residual(x))
	sandwich(invcrossmatrix(x), S)
end
function shat!(v::VcovClusterData, x::VcovData{1}) 
	# Cameron, Gelbach, & Miller (2011).
	clusternames = names(v.clusters)
	X = regressors(x)
	Xu = broadcast!(*,  X, X, residuals(x))
	S = fill(zero(Float64), (size(X, 2), size(X, 2)))
	for i in 1:length(clusternames)
		for c in combinations(clusternames, i)
			if length(c) == 1
				f = (v.clusters)[c[1]]
				# no need to group in this case
				fsize = (v.size)[c[1]]
			else
				df = v.clusters[c]
				f = group(df)
				fsize = length(f.pool)
			end
			if rem(length(c), 2) == 1
				S += helper_cluster(Xu, f, fsize)
			else
				S -= helper_cluster(Xu, f, fsize)
			end
		end
	end
	return(S)
end



function helper_cluster(Xu::Matrix{Float64}, f::PooledDataArray, fsize::Int64)
	refs = f.refs
	if fsize == size(Xu, 1)
		# if only one obs by pool, use White, as in Petersen (2009) & Thomson (2011)
		return(At_mul_B(Xu, Xu))
	else
		# otherwise
		X2 = fill(zero(Float64), (fsize, size(Xu, 2)))
		for j in 1:size(Xu, 2)
			 @inbounds @simd for i in 1:size(Xu, 1)
				X2[refs[i], j] += Xu[i, j]
			end
		end
		out = At_mul_B(X2, X2)
		scale!(out, fsize / (fsize- 1))
		return(out)
	end
end




function shat!(v::VcovClusterData, x::VcovData{2}) 
	# Cameron, Gelbach, & Miller (2011).
	clusternames = names(v.clusters)
	X = regressors(x)
	res = residuals(x)
	dim = (size(X, 2) *size(res, 2))
	S = fill(zero(Float64), (dim, dim))
	for i in 1:length(clusternames)
		for c in combinations(clusternames, i)
			if length(c) == 1
				f = (v.clusters)[c[1]]
				# no need to group in this case
				fsize = (v.size)[c[1]]
			else
				df = v.clusters[c]
				f = group(df)
				fsize = length(f.pool)
			end
			if rem(length(c), 2) == 1
				S += helper_cluster(X, res, f, fsize)
			else
				S -= helper_cluster(X, res, f, fsize)
			end
		end
	end
	return(S)
end

function helper_cluster(X::Matrix{Float64}, res::Matrix{Float64}, f::PooledDataArray, fsize::Int64)
	refs = f.refs
	dim = size(X, 2) * size(res, 2)
	if fsize == size(X, 1)
		S = fill(zero(Float64), (dim, dim))
		temp = similar(S)
		kronv = fill(zero(Float64), dim)
		@inbounds for i in 1:size(X, 1)
			j = 0
			 for l in 1:size(res, 2)
				for k in 1:size(X, 2)
					j += 1
					kronv[j] = X[i, k] * res[i, l]
				end
			end
			temp = A_mul_Bt!(temp, kronv, kronv)
			S += temp
		end
		return(S)
	else
		# otherwise
		kronv = fill(zero(Float64), fsize, dim)
		@inbounds for i in 1:size(X, 1)
			j = 0
			 for l in 1:size(res, 2)
				for k in 1:size(X, 2)
					j += 1
					kronv[refs[i], j] += X[i, k] * res[i, l]
				end
			end
		end
		S = At_mul_B(kronv, kronv)
		scale!(S, fsize / (fsize- 1))
		return(S)
	end
end









##############################################################################
##
## ranktest
## Stata ranktest  (X) (Z), wald full
##############################################################################



function rank_test!(X::Matrix{Float64}, Z::Matrix{Float64}, Pi::Matrix{Float64}, vcov_method_data::AbstractVcovMethodData, df_absorb::Int64)
	count_instruments = size(Pi, 1)
	for i in 1:min(size(Pi, 1), size(Pi, 2))
		count_instruments -= isapprox(Pi[i, i], 1.0)
	end
	crossz = At_mul_B(Z, Z)
	crossx = At_mul_B(X, X)
	K = size(crossx, 2) 
	L = size(crossz, 2) 
	p = K
	Fmatrix = cholfact(crossz, :L)[:L] 
	Gmatrix = inv(cholfact(crossx, :L)[:L])
	theta = A_mul_Bt(At_mul_B(Fmatrix, Pi),  Gmatrix)
	svd = svdfact(theta, thin = false) 
	u = svd.U
	vt = svd.Vt
	if p > 1
	    u_12 = u[1:(K-1),(K:L)]
	    v_12 = vt[1:(K-1),K]
	    u_22 = u[(K:L),(K:L)]
	    v_22 = vt[K,K]
	    a_qq = vcat(u_12, u_22) * inv(u_22) * sqrtm(A_mul_Bt(u_22, u_22))
	    b_qq = sqrtm(A_mul_Bt(v_22, v_22)) * inv(v_22') * vcat(v_12, v_22)'
	else
	    a_qq = u * inv(u) * sqrtm(A_mul_Bt(u, u))
	    b_qq = sqrtm(A_mul_Bt(vt, vt)) * inv(vt') * vt'
	end
	if typeof(vcov_method_data) == VcovSimpleData
		vhat= eye(L*K) / size(X, 1)
	else
		temp1 = convert(Matrix{eltype(Gmatrix)}, Gmatrix')
		temp2 = inv(cholfact(crossz, :L)[:L])'
		temp2 = convert(Matrix{eltype(temp2)}, temp2)
		k = kron(temp1, temp2)'
		vcovmodel = VcovData{2}(k, Z, X, size(Z, 1) - size(Z, 2) - df_absorb) 
		matrix_vcov2 = shat!(vcov_method_data, vcovmodel)
		vhat = A_mul_Bt(k * matrix_vcov2, k) 
	end
	kronv = kron(b_qq, a_qq')
	lambda = kronv * vec(theta)
	vlab = A_mul_Bt(kronv * vhat, kronv)
	invvlab = inv(cholfact!(vlab))
	r_kp = lambda' * invvlab * lambda 
	p_kp = ccdf(Chisq((L-K+1 )), r_kp[1])
	if typeof(vcov_method_data) != VcovClusterData
		F_kp = r_kp[1]  / count_instruments * (size(Z, 1) - size(Z, 2) - df_absorb)/size(Z, 1)
	else
		nclust = minimum(values(vcov_method_data.size))
		F_kp = r_kp[1]  / count_instruments * (size(Z, 1) - size(Z, 2))/(size(Z, 1)-1) * (nclust - 1) / nclust
	end
	return(F_kp, p_kp)
end


