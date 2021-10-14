


"""
For first metadata pass we need already cut the area o boolean arrays that we are intrested in and portion of metadata array that we are intrested in 
this way indexing will be simpler we will start from 0 and we will reduce memor usage


3) first metadata pass we add to the metadata offset where each block will put its main results and padding results - so all will be stored in result quueue but in diffrent spots
    we need to make ques for paddings longer than number of possible results becouse of possible modifications from neighbouring blocks that can happen simultanously
    we will establish this offsets using atomics- at this pass we will also prepare first work queue with indicies of metadata blocks and booleans indicating is it related to gold pass dilatation step or other pass

5) we do the metadata pass we analyze only those blocks that are in the borders of intrests - max min x y z was specified in step 1 , we check weather block is set to be activated
 and in case it is not full we will make it active , if the block is set as active we just add it to work queue  that is appropriate to next iteration
  - we need also to scan  the border result ques if there is any duplicate result - if so we set it to zeros and we reduce the border result counter
        of course we check it only in case new counter is bigger than old counter 


        so 1) we check metadata when metadata comply with our predicate described above we atomically increase local shared memory work queue counter
we synchronize
        -we proceed if local workqueue counter is greater than 0 
        2)  we add the local workqueue counter to global keep old value as an offset in shared memory 
        3) sync threads,  add to the work queue the data from registers of those threads that met the predicate
"""

module  MetadataAnalyzePass     


"""
we analyze metadate as described above 
minX, minY,minZ - minimal indexes of metadata that holds all of the data that is of intrest to us
maxX,maxY,maxZ  - maximal indexes of metadata that holds all of the data that is of intrest to us
metaData - global memory data structure that we analyze
shmemSum - shared memory used primary for reductions 
globalFpResOffsetCounter, globalFnResOffsetCounter  - counters accessed atomically that points where we want to set the  results from this metadata block
workQueaueA, workQueaueAcounter
"""
macro analyzeMetadataFirstPass(minX, minY,minZ, maxX,maxY,maxZ, metaData
        ,globalFpResOffsetCounter, globalFnResOffsetCounter )
        # we need to iterate over all metadata blocks with checks so the blocks can not be full outside the area of intrest defined by  minX, minY,minZ and maxX,maxY,maxZ
        @metaDataWarpIter metaData begin
            #now we upload all data related to amount of data that is of our intrest 
            @unroll for i in 1:16
                @ifXY i idY locArr= getMetaResFPOrFNcount(i, mataData,linIndex )
            end#for
            #now in order to get offsets we need to atomially access the resOffsetCounter - we add to them total fp or fn cout so next blocks will not overwrite the 
            #area that is scheduled for this particular metadata block
            @ifXY 17 idY shmemSum[idY,1]=   atomicAdd(globalFpResOffsetCounter,   round(getMetaDataTotalFpCount(metadat) *1,5)  )
            @ifXY 18 idY shmemSum[idY,2]=   atomicAdd( globalFnResOffsetCounter,  round(getMetaDataTotalFnCount(metadat) *1,5 )  )
            #as we reduced the metadata size we need now to update x,y,z coordinates 
            @ifXY 19 reduceMetaDataXYZ(metaData, minX,minY,minZ, linIndex  )
                    
            sync_warp()
            ######  we need to establish is block is active at the first pass block is active simply  when total count of fp and fn is greater than 0 
            @ifXY 19 if((shmemSum[idY,1]) >0 )  appendToWorkQueue(workQueaueA,workQueaueAcounter, linIndex, false )      end 
            @ifXY 20 if((shmemSum[idY,2]) >0 )  appendToWorkQueue(workQueaueA,workQueaueAcounter, linIndex, true )      end 
            @ifXY 21 if((shmemSum[idY,1]+shmemSum[idY,2] ) >0 )  setBlockToActive(metaData,linIndex)     end 


           #####3set offsets
            #now we will calculate and set the result queue offsets for each offset we need to synchronize warps in order to have unique offsets 
            @unroll for i in 0:7
                    #set fp
                    @ifXY i*2+1 idY begin value=shmemSum[idY,1]+ round(locArr*1.4); shmemSum[idY,1]= value ; setMetaResOffsets(i*2+1, mataData,linIndex,value )end
                    #set fn
                    @ifXY i*2+2 idY begin value=shmemSum[idY,2]+ round(locArr*1.4); shmemSum[idY,1]= value ; setMetaResOffsets(i*2+2, mataData,linIndex,value )end
                    sync_warp()
    
            end#for


        end# outer loop expession  )
        clearSharedMemWarpLong(shmemSum, UInt8(2), Float32(0.0))
        locArr=0
        
end      


"""
this will enable iteration of metadata blocks where each warp will be responsible for single block
we will use the linear indexing in order to  make it simpler    
"""

macro metaDataWarpIter(metaData, ex)
    linIndex - linear index
    idY -  thread id of warp that is responsible for this iteration
    metadat= metaData[x]
end




"""
will be invoked in order to iterate over the metadata  after some dilatations were already done - we need to 
    establish is block to be activated or inactivated or left as is
    if block is active it needs to be added to work queue 
    using some spare threads we will also housekeeping like for example switching active work queue etc
    we will check rescounters of border res ques and compare with old ones - if any will be grater than old we will scan for any repeating results 
        - it could be the case that neighbouring blocks concurently added the same results - in this case we need to set one of those to 0 and reduce the counter    
    we will do all by using single warp per metadata block     
"""
macro setMEtaDataOtherPasses()

    @metaDataWarpIter metaData begin
        @ifXY 17 idY 

    end    

    clearSharedMemWarpLong(shmemSum, UInt8(2), Float32(0.0))
    locArr=0
end




HFUtils.clearMainShmem(resShmem)
        # first we check weather next block is viable for processing
        @unroll for zIter in 1:6
 
          ----------- what is crucial those actions will be happening on diffrent threads hence when we will reduce it we will know results from all        
     
            #we will iterate over all padding planes below way to calculate the next block in all dimensions not counting oblique directions
            @ifXY 1 zIter isMaskOkForProcessing = ((currBlockX+UInt8(zIter==1)-UInt8(zIter==2))>0)
            @ifXY 2 zIter @inbounds isMaskOkForProcessing = (currBlockX+UInt8(zIter==1)-UInt8(zIter==2))<=metadataDims[1]
            @ifXY 3 zIter @inbounds isMaskOkForProcessing = (currBlockY+UInt8(zIter==3)-UInt8(zIter==4))>0
            @ifXY 4 zIter @inbounds isMaskOkForProcessing = (currBlockY+UInt8(zIter==3)-UInt8(zIter==4))<=metadataDims[2]
            @ifXY 5 zIter @inbounds isMaskOkForProcessing = (currBlockZ+UInt8(zIter==5)-UInt8(zIter==6))>0
            @ifXY 6 zIter @inbounds isMaskOkForProcessing = (currBlockZ+UInt8(zIter==5)-UInt8(zIter==6))<=metadataDims[3]
            @ifXY 7 zIter @inbounds isMaskOkForProcessing = !metaData[currBlockX+UInt8(zIter==1)-UInt8(zIter==2)
                                                            ,(currBlockY+UInt8(zIter==3)-UInt8(zIter==4))
                                                            ,(currBlockZ+UInt8(zIter==5)-UInt8(zIter==6)),isPassGold+3]#then we need to check weather mask is already full - in this case we can not activate it 
            #now we check are all true 
                 ----------- this can be done by one of the reduction macros    

           offset = UInt8(1)
            @ifY zIter begin 
                while(offset <UInt8(8)) 
                    @inbounds isMaskOkForProcessing =  isMaskOkForProcessing & shfl_down_sync(FULL_MASK, isMaskOkForProcessing, offset)
                    offset<<= 1
                end #while
            end# @ifY 
        #here is the information wheather we want to process next block
        @ifXY 1 zIter @inbounds resShmem[2,zIter+1,2] = isMaskOkForProcessing
         end#for zIter   
                
         sync_threads()#now we should know wheather we are intrested in blocks around
       
   
            
            
        # ################################################################################################################################ 
        #checking is there anything in the padding plane - so we basically do (most of reductions)
        #values stroing in local registers is there anything in padding associated # becouse we will store it in one int we can pass it at one move of registers
        locArr=0 #reset for reuse
               ----------- this was created for cubic 32x32x32 block where one plane of threads can analyze all paddings 
                   ----------- as in variable size thread blocks some of threads when processing padding will have nothing to do we can think so it will work in this time on the  isMaskForProcessing from above
        locArr|= resShmem[ 34 ,threadIdxX() , threadIdxY() ] << 1 #RIGHT
        locArr|= resShmem[1 ,threadIdxX() , threadIdxY()] << 2 #LEFT
        locArr|= resShmem[threadIdxX() ,34 ,threadIdxY() ] << 3 #ANTERIOR
        locArr|=  resShmem[ threadIdxX(),1 , threadIdxY()] << 4 #POSTERIOR
        locArr|= resShmem[ threadIdxX() , threadIdxY() ,1] << 5 #TOP
        locArr|= resShmem[ threadIdxX() , threadIdxY() ,34] << 6 #BOTTOM

   ----------- this reduction can be done probably together with reduction from step above        
                #we need to reduce now  the values  of padding vals to establish weather there is any true there if yes we put the neighbour block to be active 
                    #reduction                   
                    offset = UInt8(1)
                    while(offset <32) 
                        #we load first value from nearby thread 
                        shuffled = shfl_down_sync(FULL_MASK, locArr, offset)
                        #we loop over  bits and updating we are intrested weather there is any positive so we use or
                        @unroll for zIter::UInt8 in UInt8(1):UInt8(6)
                            locArr|= @inbounds ((shuffled>>zIter & 1) | @inbounds  (locArr>>zIter & 1) ) <<zIter
                        end#for    
                        #isMaskOkForProcessing = (isMaskOkForProcessing | 
                        offset<<= 1
                    end

                    @unroll for zIter::UInt8 in UInt8(1):UInt8(6)
                        @ifX 1  resShmem[zIter+1,threadIdxY()+1,3]=  @inbounds  (locArr>>zIter & 1)
                        #@ifX 1 CUDA.@cuprint " resShmem[zIter+1,threadIdxX()+1,3]   $(resShmem[zIter+1,threadIdxX()+1,3] )   locArr $(locArr) \n" 
                    end#for  
                             
             sync_threads()#now we have partially reduced values marking wheather we have any true in padding         
                  #  # we get full reductions
            @unroll for zIter::UInt8 in UInt8(1):UInt8(6)
                if(resShmem[2,zIter+1,2] )
                offset = UInt8(1)
                if(UInt8(threadIdxY())==zIter)
                    while(offset <32)                        
                        @inbounds  resShmem[zIter+1,threadIdxX()+1,3] = (resShmem[zIter+1,threadIdxX()+1,3] | shfl_down_sync(FULL_MASK,resShmem[zIter+1,threadIdxX()+1,3], offset))
                        offset<<= 1
                    end#while
                end#if    
                end#if                          
            end#for

            sync_threads()#now we have fully reduced in resShmem[zIter+1,1+1,3]= resShmem[zIter+1,2,3]
    
                
                
                
                
                    #updating metadata
    if(resShmem[2,primaryZiter+1,2] && resShmem[primaryZiter+1,2,3] )   
        @ifXY 2 primaryZiter @inbounds  metaData[(currBlockX+(primaryZiter==1)-(primaryZiter==2)),(currBlockY+(primaryZiter==3)-(primaryZiter==4)),(currBlockZ+(primaryZiter==5)-(primaryZiter==6)),isPassGold+1]= true
    end#if
    sync_warp()


    
    
  end #MetadataAnalyzePass
