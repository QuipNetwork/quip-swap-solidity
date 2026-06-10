1. Perhaps add `reclaimRecipient` 


Rough notes:

best path forward:
identify in the most efficient way which of the two terms is proposal vs accepting
enforce the appropriate dealdine between actions

identify under which timing conditions actions are permitted
then figure out what function to create

*********** CERTAIN **********
1. commit for proposer: any time before commitA elapses

2. commit for taker: any time after commitDeadline of proposer elapses AND before commitDeadline of taker    elapses
    ^----> if cross-chain, SC cannot check that proposer has committed 
           ** CHECKING WHETHER THE PROPOSER HAS COMMITTED IS THE TAKERS RESPONSIBILITY **
           ** USING THE SAME LOCK AS THE PROPOSER IS THE TAKERS RESPONSIBILITY ** 

 3. claim for proposer: any time before claimDeadline of proposer has elapsed 
                     AND any time after commitmentDeadline for taker has elapsed 
                     AND provided that taker has committed 
                     ^---- cross-chain cannot be verified but this is okay because 
                           secret revelation would occur so proposer is not incentivized to claim 
                           ** USER IS RESPONSIBLE TO NOT CALL CLAIM ERRONEOUSLY **

 4. claim for taker: any time after claimDeadline of proposer has elapsed AND before claim deadline of taker has elapsed

 5. reclaim for proposer: any time after claimDeadline of taker has elapsed AND before the reclaim deadline of proposer has elapsed AND 
                          if the taker has not claimed.
                          ^---- cross-chain it is possible that the the proposer claims on the destination chain and the taker
                                never claims. In this case it will be possible for the proposer to reclaim on their origin chain,
                                given enough time.

 6. reclaim for taker: any time after the reclaim deadline of the proposer has elapsed AND if the proposer has not claimed


The above comes from the realization that we are defining windows. A window may be defined as:

`struct Window {
	uint64 release;
	uint64 deadline;
}`

It seems to me that in our case ALL the windows share a boundary **ASSUMING NO DEAD TIME BETWEEN WINDOWS**. 

Below the **unedited** diagram is depicted with the window notation:

Commitments:
`WindowA {0, T_commitA-}`
`WindowB {T_commitA-, T_commitB-}`

Claims:
`WindowA {T_commitB-,  T_claimA-}` 
`WindowB {T_claimB+, T_reclaimA+}`

Slashes:
`WindowA {T_claimA-, on claim}`
`WindowB {T_commitB-, whenever off-chain system decides}`

Reclaims:
`WindowA: {T_reclaimA+, T_reclaimB+}`
`WindbowB: {T_reclaimB+, infinity}`

Below the **discussion** diagram is depicted with the window notation:

Commitments:
`WindowA {0, T_commitA-}`
`WindowB {T_commitA-, T_commitB-}`

Claims:
`WindowA {T_commitB-,  T_claimA-}` 
`WindowB {T_claimA-, T_claimB-}`

Slashes: Removed

Reclaims:
`WindowA: {T_claimB-, T_reclaimA-}`
`WindbowB: {T_reclaimA-, infinity}`


Questions:
- Is A's claim ever "prohibited" or can it happen until B's reclaim?
- 