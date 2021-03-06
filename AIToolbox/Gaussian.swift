//
//  Gaussian.swift
//  AIToolbox
//
//  Created by Kevin Coble on 4/11/16.
//  Copyright © 2016 Kevin Coble. All rights reserved.
//

import Foundation
import Accelerate


public enum GaussianError: ErrorType {
    case DimensionError
    case ZeroInVariance
    case InverseError
    case BadVarianceValue
    case DiagonalCovarianceOnly
    case ErrorInSVDParameters
    case SVDDidNotConverge
}

public class Gaussian {
    //  Parameters
    var σsquared : Double
    var mean : Double
    var multiplier : Double
    
    
    ///  Create a gaussian
    public init(mean: Double, variance: Double) throws {
        if (variance < 0.0) { throw GaussianError.BadVarianceValue }
        self.mean = mean
        σsquared = variance
        multiplier = 1.0 / sqrt(σsquared * 2.0 * M_PI)
    }
    
    public func setMean(mean: Double)
    {
        self.mean = mean
    }
    
    public func setVariance(variance: Double)
    {
        σsquared = variance
        multiplier = 1.0 / sqrt(σsquared * 2.0 * M_PI)
    }
    
    ///  Function to get the probability of an input value
    public func getProbability(input: Double) -> Double {
        let exponent = (input - mean) * (input - mean) / (-2.0 * σsquared)
        return multiplier * exp(exponent)
    }
    
    ///  Function to get a random value
    public func random() -> Double {
        return Gaussian.gaussianRandom(mean, standardDeviation: sqrt(σsquared))
    }
    
    static var y2 = 0.0
    static var use_last = false
    ///  static Function to get a random value for a given distribution
    public static func gaussianRandom(mean : Double, standardDeviation : Double) -> Double
    {
        var y1 : Double
        if (use_last)		        /* use value from previous call */
        {
            y1 = y2
            use_last = false
        }
        else
        {
            var w = 1.0
            var x1 = 0.0
            var x2 = 0.0
            repeat {
                x1 = 2.0 * (Double(arc4random()) / Double(UInt32.max)) - 1.0
                x2 = 2.0 * (Double(arc4random()) / Double(UInt32.max)) - 1.0
                w = x1 * x1 + x2 * x2
            } while ( w >= 1.0 )
            
            w = sqrt( (-2.0 * log( w ) ) / w )
            y1 = x1 * w
            y2 = x2 * w
            use_last = true
        }
        
        return( mean + y1 * standardDeviation )
    }
}

public class MultivariateGaussian {
    
    //  Parameters
    let dimension: Int
    let diagonalΣ : Bool
    var μ : [Double]    //  Mean
    var Σ : [Double]    //  Covariance.  If diagonal, then vector, else column-major square matrix (column major for LAPACK)
    
    //  Calculate values for computing probability
    var haveCalcValues = false
    var multiplier : Double       //  The 1/(2π) ^ (dimension / 2) sqrt(detΣ)
    var invΣ : [Double]     //  Inverse of Σ (1/Σ if diagonal)
    
    
    ///  Create a multivariate gaussian.  dimension should be 2 or greater
    public init(dimension: Int, diagonalCovariance: Bool = true) throws {
        self.dimension = dimension
        diagonalΣ = diagonalCovariance
        if (dimension < 2) { throw GaussianError.DimensionError }
        
        //  Start with 0 mean
        μ = [Double](count: dimension, repeatedValue: 0.0)
        
        //  Start with the identity matrix for covariance
        if (diagonalΣ) {
            Σ = [Double](count: dimension, repeatedValue: 1.0)
            invΣ = [Double](count: dimension, repeatedValue: 1.0)
        }
        else {
            Σ = [Double](count: dimension * dimension, repeatedValue: 0.0)
            for index in 0..<dimension { Σ[index * dimension + index] = 1.0 }
            invΣ = [Double](count: dimension * dimension, repeatedValue: 0.0)       //  Will get calculated later
        }
        
        //  Set the multiplier temporarily
        multiplier = 1.0
    }
    
    private func getComputeValues() throws {
        var denominator = pow(2.0 * M_PI, Double(dimension) * 0.5)
        
        //  Get the determinant and inverse of the covariance matrix
        var sqrtDeterminant = 1.0
        if (diagonalΣ) {
            for index in 0..<dimension {
                sqrtDeterminant *= Σ[index]
                invΣ[index] = 1.0 / Σ[index]
            }
            sqrtDeterminant = sqrt(sqrtDeterminant)
        }
        else {
            let uploChar = "U" as NSString
            var uplo : Int8 = Int8(uploChar.characterAtIndex(0))          //  use upper triangle
            var A = Σ       //  Make a copy so it isn't mangled
            var n : Int32 = Int32(dimension)
            var info : Int32 = 0
            dpotrf_(&uplo, &n, &A, &n, &info)
            if (info != 0) { throw GaussianError.InverseError }
            //  Extract sqrtDeterminant from U by multiplying the diagonal  (U is multiplied by Utranspose after factorization)
            for index in 0..<dimension {
                sqrtDeterminant *= A[index * dimension + index]
            }
            
            //  Get the inverse
            dpotri_(&uplo, &n, &A, &n, &info)
            if (info != 0) { throw GaussianError.InverseError }
            
            //  Convert inverse U into symmetric full matrix for matrix multiply routines
            for row in 0..<dimension {
                for column in row..<dimension {
                    invΣ[row * dimension + column] = A[column * dimension + row]
                    invΣ[column * dimension + row] = A[column * dimension + row]
                }
           }
        }
        
        denominator *= sqrtDeterminant
        
        if (denominator == 0.0) { throw GaussianError.ZeroInVariance }
        multiplier = 1.0 / denominator
        
        haveCalcValues = true
    }
    
    ///  Function to set the mean
    public func setMean(mean: [Double]) throws {
        if (mean.count != dimension) { throw GaussianError.DimensionError }
        μ = mean
    }
    
    
    ///  Function to set the covariance values.  Values are copied into symmetric sides of matrix
    public func setCoVariance(inputIndex1: Int, inputIndex2: Int, value: Double) throws {
        if (value < 0.0) { throw GaussianError.BadVarianceValue }
        if (inputIndex1 < 0 || inputIndex1 >= dimension) { throw GaussianError.BadVarianceValue }
        if (inputIndex2 < 0 || inputIndex2 >= dimension) { throw GaussianError.BadVarianceValue }
        if (diagonalΣ && inputIndex1 != inputIndex2) { throw GaussianError.DiagonalCovarianceOnly }
        
        Σ[inputIndex1 * dimension + inputIndex2] = value
        Σ[inputIndex2 * dimension + inputIndex1] = value
        
        haveCalcValues = false
    }
    
    public func setCovarianceMatrix(matrix: [Double]) throws {
        if (diagonalΣ && matrix.count != dimension) { throw GaussianError.DiagonalCovarianceOnly }
        if (!diagonalΣ && matrix.count != dimension * dimension) { throw GaussianError.DimensionError }
        Σ = matrix
        haveCalcValues = false
    }
    
    ///  Function to get the probability of an input vector
    public func getProbability(inputs: [Double]) throws -> Double {
        if (inputs.count != dimension) { throw GaussianError.DimensionError }
        if (!haveCalcValues) {
            do {
                try getComputeValues()
            }
            catch let error {
                throw error
            }
        }
        
        //  Subtract the mean
        var relative = [Double](count: dimension, repeatedValue: 0.0)
        vDSP_vsubD(μ, 1, inputs, 1, &relative, 1, vDSP_Length(dimension))
        
        //  Determine the exponent
        var partial = [Double](count: dimension, repeatedValue: 0.0)
        if (diagonalΣ) {
            vDSP_vmulD(relative, 1, invΣ, 1, &partial, 1, vDSP_Length(dimension))
        }
        else {
            vDSP_mmulD(invΣ, 1, relative, 1, &partial, 1, vDSP_Length(dimension), vDSP_Length(1), vDSP_Length(dimension))
        }
        var exponent = 1.0
        vDSP_dotprD(partial, 1, relative, 1, &exponent, vDSP_Length(dimension))
        exponent *= -0.5
        
        return exp(exponent) * multiplier
    }
    
    ///  Function to get a set of random vectors
    ///  Setup is computationaly expensive, so call once to get multiple vectors
    public func random(count: Int) throws -> [[Double]] {
        var sqrtEigenValues = [Double](count: dimension, repeatedValue: 0.0)
        var translationMatrix = [Double](count: dimension*dimension, repeatedValue: 0.0)
        if (diagonalΣ) {
            //  eigenValues are the diagonals - get sqrt of them for multiplication
            for element in 0..<dimension {
                sqrtEigenValues[element] = sqrt(Σ[element])
            }
        }
        else {
            //  If a non-diagonal covariance matrix, get the eigenvalues and eigenvectors
            //  Get the SVD decomposition of the Σ matrix
            let jobZChar = "S" as NSString
            var jobZ : Int8 = Int8(jobZChar.characterAtIndex(0))          //  return min(m,n) rows of Σ
            var n : Int32 = Int32(dimension)
            var u = [Double](count: dimension * dimension, repeatedValue: 0.0)
            var work : [Double] = [0.0]
            var lwork : Int32 = -1        //  Ask for the best size of the work array
            let iworkSize = 8 * dimension
            var iwork = [Int32](count: iworkSize, repeatedValue: 0)
            var info : Int32 = 0
            var A = Σ       //  Leave Σ intact
            var eigenValues = [Double](count: dimension, repeatedValue: 0.0)
            var eigenVectors = [Double](count: dimension*dimension, repeatedValue: 0.0)
            dgesdd_(&jobZ, &n, &n, &A, &n, &eigenValues, &u, &n, &eigenVectors, &n, &work, &lwork, &iwork, &info)
            if (info != 0 || work[0] < 1) {
                throw GaussianError.ErrorInSVDParameters
            }
            lwork = Int32(work[0])
            work = [Double](count: Int(work[0]), repeatedValue: 0.0)
            dgesdd_(&jobZ, &n, &n, &A, &n, &eigenValues, &u, &n, &eigenVectors, &n, &work, &lwork, &iwork, &info)
            if (info < 0) {
                throw GaussianError.ErrorInSVDParameters
            }
            if (info > 0) {
                throw GaussianError.SVDDidNotConverge
            }
            
            //  Extract the eigenvectors multiplied by the square root of the eigenvalues - make a row-major matrix for dataset vector multiplication using vDSP
            for vector in 0..<dimension {
                let sqrtEigenValue = sqrt(eigenValues[vector])
                for column in 0..<dimension {
                    translationMatrix[(vector * dimension) + column] = eigenValues[vector + (column * dimension)] * sqrtEigenValue
                }
            }
        }
        
        //  Get a set of vectors
        var results : [[Double]] = []
        for _ in 0..<count {
            //  Get random uniform vector
            var entry = [Double](count: dimension, repeatedValue: 0.0)
            for element in 0..<dimension {
                entry[element] = Gaussian.gaussianRandom(0.0, standardDeviation: 1.0)
            }
            
            //  Extend vector based on the covariance matrix
            if (diagonalΣ) {
                //  Since diagonal, the eigenvectors are unit vectors, so just multiply each element by the square root of the eigenvalues - which are the diagonal elements
                vDSP_vmulD(entry, 1, sqrtEigenValues, 1, &entry, 1, vDSP_Length(dimension))
            }
            else {
                vDSP_mmulD(translationMatrix, 1, entry, 1, &entry, 1, vDSP_Length(dimension), vDSP_Length(1), vDSP_Length(dimension))
            }
            
            //  Add the mean
            vDSP_vaddD(entry, 1, μ, 1, &entry, 1, vDSP_Length(dimension))
            
            //  Insert vector into return results
            results.append((entry))
        }
        return results
    }
}
