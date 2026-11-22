import { useEffect, useMemo, useRef, useState, type ReactNode, type DragEvent, type MouseEvent } from 'react'
import { ArrowRight, ClipboardCopy, ShieldCheck } from 'lucide-react'
import { players } from './data/players'
import { drawAuctionPool, shuffleQueue, STARTER_POOL_SIZE, CATEGORY_ORDER, categoryCounts, categoryQuotas } from './lib/pool'
import { getPlayer } from './lib/game'
import { autoPlacePlayers, defaultRole, eligibleRoles, formationLabel, roleLabel, roleInitialPosition, roleFromCoordinates, tacticalRoles } from './lib/tactics'
import { calculateTeamResults } from './lib/results'
import {
  createOnlineRoom, ensureAnonymousSession, fetchRoom, getRoomLobby, joinOnlineRoom,
  kickOnlineTeam, leaveOnlineRoom, placeOnlineBid, quitOnlineLot, startNextOnlinePlayer, subscribeRoom, submitMyTeam, updateMyTeam
} from './lib/online'
import { hasSupabaseConfig } from './lib/supabase'
import type { Player, PlayerCategory, PlayerPlacement, RoomState, Settings, Team, TacticalRole } from './types'
import type { TeamResult } from './lib/results'

const fmt=(n:number)=>`${Math.round(n).toLocaleString('en-IN')} pts`
const defaultTeamNames='Team Alpha\nTeam Bravo\nTeam Charlie\nTeam Delta'

function buildAutoLineup(team:Team,pool:Player[]):PlayerPlacement[]{
  return autoPlacePlayers(team.purchases,pool,team.lineup??[])
}
function categoryLabel(category:string):string{return category==='Icon'?'ICON':category==='Hero'?'HERO':'CURRENT'}

function App(){
  const [tab,setTab]=useState<'create'|'join'>('create')
  const [authReady,setAuthReady]=useState(false)
  const [loading,setLoading]=useState(false)
  const [error,setError]=useState('')
  const [notice,setNotice]=useState('')
  const [teamNames,setTeamNames]=useState(defaultTeamNames)
  const [budget,setBudget]=useState('1800')
  const [squadSize,setSquadSize]=useState(18)
  const initialCategoryCounts=categoryQuotas(STARTER_POOL_SIZE)
  const [categorySelection,setCategorySelection]=useState<Record<PlayerCategory,string>>({
    Current:String(initialCategoryCounts.Current),Icon:String(initialCategoryCounts.Icon),Hero:String(initialCategoryCounts.Hero)
  })
  const [priceMultipliers,setPriceMultipliers]=useState<Record<PlayerCategory,string>>({Current:'1.0',Icon:'1.0',Hero:'1.0'})
  const [joinCode,setJoinCode]=useState('')
  const [lobbyInfo,setLobbyInfo]=useState<Awaited<ReturnType<typeof getRoomLobby>>|null>(null)
  const [room,setRoom]=useState<RoomState|null>(null)
  const [activeView,setActiveView]=useState<'auction'|'squads'|'results'>('auction')
  const [editingLineup,setEditingLineup]=useState<PlayerPlacement[]>([])
  const [actionBusy,setActionBusy]=useState(false)
  const [auctionAnnouncement,setAuctionAnnouncement]=useState<{kind:'sold'|'unsold';player:string;team?:string;amount?:number}|null>(null)
  const lastRoomMessage=useRef<{roomId:string;message:string}|null>(null)
  const announcementTimer=useRef<number|null>(null)

  const myTeam=room?.teams.find(t=>t.id===room.myTeamId)
  const currentPlayer=room?.currentPlayer??null
  const myIsActive=Boolean(room&&myTeam&&room.activeTeamIds.includes(myTeam.id))
  const myIsHighest=Boolean(room&&myTeam&&room.highestBidderTeamId===myTeam.id)
  const highestBidTeam=room?.teams.find(team=>team.id===room.highestBidderTeamId)
  const currentMinimum=room?(room.highestBidderTeamId?room.currentBid+1:room.currentBid):0
  const categoryCount=useMemo(()=>categoryCounts(players),[])
  const selectedCategoryQuota={Current:Number(categorySelection.Current||0),Icon:Number(categorySelection.Icon||0),Hero:Number(categorySelection.Hero||0)}
  const poolSize=selectedCategoryQuota.Current+selectedCategoryQuota.Icon+selectedCategoryQuota.Hero
  const numericPriceMultipliers={Current:Number(priceMultipliers.Current),Icon:Number(priceMultipliers.Icon),Hero:Number(priceMultipliers.Hero)}
  const allTeamsSubmitted=Boolean(room && room.status==='finished' && room.teams.length>0 &&
    room.teams.every(team=>team.isSeated && team.submitted))
  const results=useMemo(()=>room?calculateTeamResults(room.teams,room.poolPlayers,room.settings.squadSize):[],[room?.teams,room?.poolPlayers,room?.settings.squadSize])

  useEffect(()=>{
    if(allTeamsSubmitted)setActiveView('results')
  },[allTeamsSubmitted])

  useEffect(()=>{
    if(!hasSupabaseConfig)return
    let alive=true
    ensureAnonymousSession().then(()=>{if(alive)setAuthReady(true)}).catch(e=>{if(alive){setError(message(e));setAuthReady(true)}})
    return ()=>{alive=false}
  },[])

  useEffect(()=>{
    if(!authReady)return
    const saved=localStorage.getItem('footbid-v08-room')
    if(!saved||!hasSupabaseConfig)return
    let cancelled=false
    fetchRoom(saved).then(r=>{if(!cancelled){setRoom(r)}}).catch(e=>{if(!cancelled)setError(`Could not restore the last room on this device: ${message(e)}`)})
    return ()=>{cancelled=true}
  },[authReady])

  useEffect(()=>{
    if(!room?.id)return
    let cancelled=false
    let cleanup:(()=>void)|null=null
    subscribeRoom(room.code,room.id,()=>{
      fetchRoom(room.code).then(next=>{if(!cancelled)setRoom(next)}).catch(()=>{})
    }).then(fn=>{if(cancelled)fn();else cleanup=fn}).catch(e=>setError(message(e)))
    return ()=>{cancelled=true;cleanup?.()}
  },[room?.id,room?.code])

  useEffect(()=>{
    if(!room)return
    const previous=lastRoomMessage.current
    if(!previous||previous.roomId!==room.id){
      lastRoomMessage.current={roomId:room.id,message:room.lastMessage}
      return
    }
    if(previous.message===room.lastMessage)return
    lastRoomMessage.current={roomId:room.id,message:room.lastMessage}
    const sold=room.lastMessage.match(/^SOLD!\s+(.+?)\s+goes to\s+(.+?)\s+for\s+(\d+)\s+points/i)
    const unsold=room.lastMessage.match(/^UNSOLD!\s+(.+?)\s+received no bids/i)
    if(sold){
      setAuctionAnnouncement({kind:'sold',player:sold[1],team:sold[2],amount:Number(sold[3])})
    }else if(unsold){
      setAuctionAnnouncement({kind:'unsold',player:unsold[1]})
    }
    if(sold||unsold){
      if(announcementTimer.current!==null)window.clearTimeout(announcementTimer.current)
      announcementTimer.current=window.setTimeout(()=>setAuctionAnnouncement(null),6500)
    }
  },[room?.id,room?.lastMessage])

  useEffect(()=>()=>{
    if(announcementTimer.current!==null)window.clearTimeout(announcementTimer.current)
  },[])

  useEffect(()=>{
    if(!myTeam || !room)return
    const lineup=buildAutoLineup(myTeam,room.poolPlayers)
    setEditingLineup(lineup)
    const before=JSON.stringify(myTeam.lineup??[])
    const after=JSON.stringify(lineup)
    if(!myTeam.submitted && before!==after){
      updateMyTeam(room.code,'CUSTOM',lineup)
        .then(()=>fetchRoom(room.code).then(setRoom))
        .catch(e=>setError(`Could not sync the updated tactical lineup: ${message(e)}`))
    }
  },[room?.id,room?.myTeamId,myTeam?.id,myTeam?.purchases.length,myTeam?.formation])

  function message(e:unknown):string{
    if(typeof e==='string') return e
    if(e && typeof e==='object'){
      const err=e as Record<string,unknown>
      const parts:string[]=[]
      if(typeof err.message==='string' && err.message.trim()) parts.push(err.message.trim())
      if(typeof err.details==='string' && err.details.trim()) parts.push(`Details: ${err.details.trim()}`)
      if(typeof err.hint==='string' && err.hint.trim()) parts.push(`Hint: ${err.hint.trim()}`)
      if(typeof err.code==='string' && err.code.trim()) parts.push(`Code: ${err.code.trim()}`)
      if(typeof err.status==='number') parts.push(`HTTP status: ${err.status}`)
      if(parts.length) return parts.join('\n')
      try{return JSON.stringify(e,null,2)}catch{return 'An unknown object error occurred. Check the browser console.'}
    }
    if(e instanceof Error) return e.message
    return String(e)
  }
  async function refresh(code:string){
    const next=await fetchRoom(code)
    setRoom(next)
    localStorage.setItem('footbid-v08-room',code)
    return next
  }
  async function createRoom(){
    setLoading(true);setError('');setNotice('')
    try{
      const names=teamNames.split(/[\n,]/).map(s=>s.trim()).filter(Boolean)
      if(names.length<2||names.length>8)throw new Error('Enter between 2 and 8 team names.')
      if(new Set(names.map(s=>s.toLowerCase())).size!==names.length)throw new Error('Team names must be unique.')
      if(!Number.isInteger(Number(budget))||Number(budget)<500)throw new Error('Set a whole-number team budget of at least 500 points.')
      if(![11,15,18].includes(squadSize))throw new Error('Choose a squad size of 11, 15 or 18 players.')
      const counts=selectedCategoryQuota
      for(const category of CATEGORY_ORDER){
        if(!Number.isInteger(counts[category])||counts[category]<0||counts[category]>categoryCount[category])throw new Error(category+' count must be between 0 and '+categoryCount[category]+'.')
      }
      if(poolSize<STARTER_POOL_SIZE||poolSize>players.length)throw new Error('Choose at least '+STARTER_POOL_SIZE+' players and no more than '+players.length+'.')
      if(poolSize<names.length*squadSize)throw new Error('This room needs at least '+(names.length*squadSize)+' players for '+names.length+' full squads. Increase your category counts.')
      if(CATEGORY_ORDER.some(category=>!Number.isFinite(numericPriceMultipliers[category])||numericPriceMultipliers[category]<0.5||numericPriceMultipliers[category]>3))throw new Error('Each category price multiplier must be between 0.5 and 3.0.')
      const pool=drawAuctionPool(poolSize,counts)
      const settings:Settings={budget:Number(budget),squadSize,auctionPoolSize:pool.length,categoryCounts:counts,openingPriceMultipliers:numericPriceMultipliers}
      const created=await createOnlineRoom({teamNames:names,settings,pool,queue:shuffleQueue(pool)})
      await refresh(created.room_code)
      setNotice(`Room ${created.room_code} created. You control ${names[0]}. Share the code with the other contestants.`)
    }catch(e){console.error('FootBid room creation failed:',e);setError(message(e))}
    finally{setLoading(false)}
  }
  async function lookupRoom(){
    setLoading(true);setError('');setNotice('');setLobbyInfo(null)
    try{
      await ensureAnonymousSession()
      const info=await getRoomLobby(joinCode.trim())
      setLobbyInfo(info)
      if(info.my_team_id){
        await refresh(info.room_code)
      }else if(info.status!=='lobby'){
        throw new Error('This auction has already started and no team is assigned to this device.')
      }
    }catch(e){setError(message(e))}
    finally{setLoading(false)}
  }
  async function claimTeam(teamId:string){
    if(!lobbyInfo)return
    setLoading(true);setError('')
    try{
      await joinOnlineRoom(lobbyInfo.room_code,teamId)
      await refresh(lobbyInfo.room_code)
      setNotice('Team joined. Your phone can now control this team only.')
    }catch(e){setError(message(e))}
    finally{setLoading(false)}
  }
  async function runAction(action:()=>Promise<unknown>,success?:string){
    setActionBusy(true);setError('');setNotice('')
    try{
      await action()
      if(room)await refresh(room.code)
      if(success)setNotice(success)
    }catch(e){setError(message(e))}
    finally{setActionBusy(false)}
  }
  async function placeBid(amount:number){
    if(!room||!myTeam)return
    if(!Number.isInteger(amount)||amount<currentMinimum){setError('The next valid bid is '+fmt(currentMinimum)+' or higher.');return}
    if(amount>myTeam.budgetRemaining){setError('Your team has only '+fmt(myTeam.budgetRemaining)+' left. Choose a smaller increment.');return}
    await runAction(()=>placeOnlineBid(room.code,amount),'Bid submitted: '+fmt(amount)+'.')
  }
  async function quitLot(){
    if(!room||!myTeam||myIsHighest||!myIsActive)return
    await runAction(()=>quitOnlineLot(room.code),'Your team has quit this player auction.')
  }
  async function kickTeam(teamId:string,teamName:string){
    if(!room||!room.isHost)return
    if(!window.confirm('Remove '+teamName+' from this auction? Their team and seat will be removed.'))return
    await runAction(()=>kickOnlineTeam(room.code,teamId),teamName+' was removed from the room.')
  }
  async function revealNext(){
    if(!room)return
    await runAction(()=>startNextOnlinePlayer(room.code))
  }
  async function saveFormation(){
    if(!room||!myTeam||myTeam.submitted)return
    await runAction(()=>updateMyTeam(room.code,'CUSTOM',editingLineup),'Your tactical lineup is saved.')
  }
  async function saveLineup(next:PlayerPlacement[],success='Tactical positioning updated.'){
    if(!room||!myTeam||myTeam.submitted)return
    setEditingLineup(next)
    setActionBusy(true);setError('')
    try{await updateMyTeam(room.code,'CUSTOM',next);await refresh(room.code);setNotice(success)}
    catch(e){setError(message(e))}
    finally{setActionBusy(false)}
  }
  async function movePlayer(playerId:string,x:number,y:number){
    if(!room||!myTeam||myTeam.submitted)return
    const existing=editingLineup.find(p=>p.playerId===playerId)
    if(existing){
      const next=editingLineup.map(p=>p.playerId===playerId?{...p,x,y,role:roleFromCoordinates(x,y)}:p)
      await saveLineup(next,'Player moved on the tactical pitch.')
      return
    }
    if(editingLineup.length>=11){setError('Your starting XI already has 11 players. Remove a player from the pitch before adding another.');return}
    const player=getPlayer(playerId,room.poolPlayers)
    if(!player)return
    const role=roleFromCoordinates(x,y)
    const next=[...editingLineup,{playerId,role,x,y}]
    await saveLineup(next,`${player.name} added to your starting XI.`)
  }
  async function changePlayerRole(playerId:string,role:TacticalRole){
    if(!room||!myTeam||myTeam.submitted)return
    const player=getPlayer(playerId,room.poolPlayers)
    if(!player)return
    const point=roleInitialPosition[role]
    const next=editingLineup.map(p=>p.playerId===playerId?{...p,role,x:point.x,y:point.y}:p)
    await saveLineup(next,`${player.name} moved to ${role}. Out-of-position use is allowed and is reflected in squad analysis.`)
  }
  async function removePlayerFromXI(playerId:string){
    if(!room||!myTeam||myTeam.submitted)return
    await saveLineup(editingLineup.filter(p=>p.playerId!==playerId),'Player moved to the bench.')
  }
  async function submitTeam(){
    if(!room)return
    await runAction(()=>submitMyTeam(room.code),'Your final team has been submitted and locked.')
  }
  async function leaveRoom(){
    if(room&&!room.isHost){
      setActionBusy(true);setError('')
      try{await leaveOnlineRoom(room.code)}catch(e){setError(message(e));setActionBusy(false);return}
      finally{setActionBusy(false)}
    }
    localStorage.removeItem('footbid-v08-room')
    setRoom(null);setLobbyInfo(null);setError('');setNotice('')
  }
  function copyCode(){
    if(room)navigator.clipboard?.writeText(room.code).then(()=>setNotice('Room code copied.')).catch(()=>setNotice(`Room code: ${room.code}`))
  }

  if(!hasSupabaseConfig){
    return <Shell><section className="connect-card">
      <div className="eyebrow"><span className="eyebrow-line"/> MULTIPLAYER BACKEND REQUIRED</div>
      <h1>Bring your<br/><em>crew online.</em></h1>
      <p>FootBid v0.8 uses the uploaded 489-player dataset and flexible tactical positioning. Add your Supabase project settings to enable room codes, private team control and live updates across phones.</p>
      <div className="connect-steps"><b>1.</b> Copy <code>.env.example</code> to <code>.env</code><b>2.</b> Add your Supabase URL and anon key<b>3.</b> Run <code>supabase/schema.sql</code> in the SQL Editor.</div>
      <p className="muted">Do not put a service-role key in the browser. Use the project publishable/anon key only.</p>
    </section></Shell>
  }
  if(!authReady)return <Shell><section className="connect-card"><h2>Connecting your contestant device…</h2><p>Creating a secure guest identity for this browser.</p></section></Shell>
  return <Shell>
    {!room?<section className="setup-layout v05-setup">
      <div className="intro-copy">
        <div className="eyebrow"><span className="eyebrow-line"/> BUILD YOUR ALL-TIME XI</div>
        <h1>The market<br/>is <em>open.</em></h1>
        <p className="intro-lead">One room. Four phones. Your own team. Everyone watches the market, but only you control your side.</p>
        <div className="intro-stats"><div><b>{players.length}</b><span>PLAYER CANDIDATES</span></div><div><b>{poolSize}</b><span>PLAYERS IN THIS AUCTION</span></div><div><b>03</b><span>PLAYER CATEGORIES</span></div></div>
        <div className="tier-guide dataset-guide">
          <div className="tier-guide-head"><span>UPLOADED PLAYER DATABASE</span><span>489 PLAYERS</span></div>
          {CATEGORY_ORDER.map(category=><div className="tier-guide-row" key={category}><span className={`tier-dot category-${category.toLowerCase()}`}/><b>{category.toUpperCase()}</b><span className="tier-available">{categoryCount[category]} players</span><strong>{selectedCategoryQuota[category]} / {poolSize}</strong></div>)}
        </div>
      </div>
      <div className="setup-card">
        <div className="setup-tabs"><button className={tab==='create'?'active':''} onClick={()=>{setTab('create');setError('')}}>CREATE ROOM</button><button className={tab==='join'?'active':''} onClick={()=>{setTab('join');setError('')}}>JOIN ROOM</button></div>
        {tab==='create'?<>
          <div className="setup-card-title"><div><div className="eyebrow">ORGANISER CONTROLS</div><h2>Set up your auction</h2></div><div className="auction-stamp">01<br/><small>HOST</small></div></div>
          <label className="field-label">TEAM NAMES <span>2–8 teams · one name per line · first team is the organiser</span></label>
          <textarea className="team-input" rows={4} value={teamNames} onChange={e=>setTeamNames(e.target.value)}/>
          <div className="field-grid two">
            <label className="field-label">TEAM BUDGET<input type="text" inputMode="numeric" pattern="[0-9]*" value={budget} onChange={e=>setBudget(e.target.value.replace(/\D/g,''))}/></label>
            <div className="squad-size-field"><span className="field-label">SQUAD SIZE</span><div className="squad-size-buttons">{[11,15,18].map(size=><button type="button" key={size} className={squadSize===size?'selected':''} onClick={()=>setSquadSize(size)}>{size}</button>)}</div><small>PLAYERS PER TEAM</small></div>
          </div>
          <div className="category-count-controls">
            <div className="category-count-heading"><div><b>PLAYERS IN THIS AUCTION</b><span>Set the exact number of Current, Icon and Hero players. No automatic split.</span></div><strong>{poolSize} <small>/ 489</small></strong></div>
            {CATEGORY_ORDER.map(category=><label className="category-count-row" key={category}>
              <span className={'category-price-dot category-'+category.toLowerCase()}/><b>{category.toUpperCase()}</b>
              <span className="category-count-available">Max {categoryCount[category]}</span>
              <input type="text" inputMode="numeric" pattern="[0-9]*" maxLength={3} value={categorySelection[category]} onChange={e=>setCategorySelection(prev=>({...prev,[category]:e.target.value.replace(/\D/g,'')}))} aria-label={category+' player count'}/>
            </label>)}
            <small className="category-count-total">Selected total: {poolSize} players · Minimum 90 · Maximum 489.</small>
          </div>
          <div className="category-price-controls">
            <div className="category-price-heading"><div><b>CATEGORY OPENING PRICE</b><span>Player dataset base price × your multiplier. Set each category separately.</span></div><small>DEFAULT 1.0×</small></div>
            {(['Current','Icon','Hero'] as const).map(category=><label className="category-price-row" key={category}>
              <span className={`category-price-dot category-${category.toLowerCase()}`}/><b>{category.toUpperCase()}</b>
              <span className="category-price-example">{category==='Current'?'Current players':category==='Icon'?'All-time Icons':'Heroes'}</span>
              <div><input type="text" inputMode="decimal" pattern="[0-9.]*" value={priceMultipliers[category]} onChange={e=>setPriceMultipliers(prev=>({...prev,[category]:e.target.value.replace(/[^0-9.]/g,'')}))}/><small>× base price</small></div>
            </label>)}
          </div>
          <button className="primary-button full" disabled={loading} onClick={createRoom}>{loading?'CREATING ROOM…':'CREATE MULTIPLAYER ROOM'} <ArrowRight size={15}/></button>
          <p className="setup-footnote">Selected squad: {squadSize} players · {Math.max(0,squadSize-11)} bench places. The 489-player dataset supplies each player's category, listed positions, image and base price.</p>
        </>:<>
          <div className="setup-card-title"><div><div className="eyebrow">CONTESTANT ENTRY</div><h2>Join your friends</h2></div><div className="auction-stamp">02<br/><small>JOIN</small></div></div>
          <label className="field-label">ROOM CODE <span>Ask the organiser for the six-character code.</span><input className="room-code-input" value={joinCode} onChange={e=>setJoinCode(e.target.value.toUpperCase().replace(/[^A-Z0-9]/g,'').slice(0,6))} maxLength={6} placeholder="e.g. A7K9P2"/></label>
          <button className="primary-button full" disabled={loading||joinCode.length!==6} onClick={lookupRoom}>{loading?'LOOKING UP…':'FIND ROOM'} <ArrowRight size={15}/></button>
          {lobbyInfo&&<div className="seat-picker"><b>Choose your team</b><span>{lobbyInfo.room_code} · {lobbyInfo.status.toUpperCase()}</span>
            {lobbyInfo.teams.map(t=><button key={t.id} disabled={t.is_seated||lobbyInfo.status!=='lobby'} onClick={()=>claimTeam(t.id)}><span>{t.team_name}</span><small>{t.is_seated?'TAKEN':'OPEN SEAT'}</small></button>)}
          </div>}
          <p className="setup-footnote">Each device claims one team. A team seat cannot be claimed by a second device.</p>
        </>}
        {error&&<p className="error-note">{error}</p>}
      </div>
    </section>:<>
      <div className="workspace-head">
        <div><div className="eyebrow"><span className="eyebrow-line"/> ROOM {room.code} · {myTeam?.teamName}</div><h1>{activeView==='results'?'Final ':room.status==='lobby'?'The ':room.status==='finished'?'Final ':'Live '}<em>{activeView==='results'?'results':room.status==='lobby'?'lobby':activeView==='squads'?'squads':'auction'}</em></h1></div>
        <div className="workspace-controls">
          <span className="live-status"><i className={room.status==='live'?'live':''}/>{room.status.toUpperCase()}</span>
          <button className={`quiet-button ${activeView==='auction'?'active-view':''}`} onClick={()=>setActiveView('auction')}>Auction</button>
          <button className={`quiet-button ${activeView==='squads'?'active-view':''}`} onClick={()=>setActiveView('squads')}>Squads</button>
          <button className={`quiet-button ${activeView==='results'?'active-view':''}`} disabled={room.status!=='finished'} onClick={()=>setActiveView('results')}>{allTeamsSubmitted?'Results 🏆':room.status==='finished'?'Results · pending':'Results · locked'}</button>
          <button className="quiet-button" onClick={leaveRoom}>Leave</button>
        </div>
      </div>
      {notice&&<div className="notice-banner">{notice}</div>}
      {error&&<div className="error-banner">{error}</div>}
      <HostKickControls room={room} onKick={kickTeam}/>
      {auctionAnnouncement&&<div className={`auction-announcement ${auctionAnnouncement.kind}`} role="status" aria-live="assertive">
        <button className="announcement-close" onClick={()=>setAuctionAnnouncement(null)} aria-label="Dismiss announcement">×</button>
        <span className="announcement-kicker">{auctionAnnouncement.kind==='sold'?'⚽ PLAYER SOLD':'○ PLAYER UNSOLD'}</span>
        <strong>{auctionAnnouncement.player}</strong>
        {auctionAnnouncement.kind==='sold'
          ? <p>Sold to <b>{auctionAnnouncement.team}</b> for <b>{fmt(auctionAnnouncement.amount??0)}</b>.</p>
          : <p>No bids received. This player is unsold.</p>}
        <small>The next player is already on the block.</small>
      </div>}
      {room.status==='lobby'?<section className="lobby-layout">
        <div className="lot-card lobby-main">
          <div className="eyebrow">ROOM LOBBY</div>
          <h2>Waiting for all contestants.</h2>
          <p>Share this code with your friends. Each person opens FootBid on their own device and claims their team.</p>
          <button className="room-code-share" onClick={copyCode}><strong>{room.code}</strong><ClipboardCopy size={18}/><small>COPY CODE</small></button>
          <div className="seat-grid">{room.teams.map(t=><div className={`seat-card ${t.isSeated?'claimed':''} ${t.isMine?'mine':''}`} key={t.id}><span className="team-avatar">{t.teamName.slice(0,1)}</span><div><b>{t.teamName}</b><small>{t.isMine?'YOUR TEAM':t.isSeated?'CONTESTANT JOINED':'WAITING FOR CONTESTANT'}</small></div>{t.isSeated?<ShieldCheck className="seat-check"/>:<span className="seat-open">OPEN</span>}</div>)}</div>
          {room.isHost?<button className="primary-button full" disabled={room.teams.some(t=>!t.isSeated)||loading} onClick={revealNext}>START AUCTION · REVEAL FIRST PLAYER <ArrowRight size={15}/></button>:<p className="setup-footnote">Waiting for the organiser to start once every team has joined.</p>}
          {room.teams.some(t=>!t.isSeated)&&<p className="muted">Joined: {room.teams.filter(t=>t.isSeated).length} / {room.teams.length} teams.</p>}
        </div>
        <aside className="side-card lobby-side"><div className="side-card-head"><span>ROOM SETTINGS</span><small>LOCKED</small></div><div className="market-stat"><span>Team budget</span><b>{fmt(room.settings.budget)}</b></div><div className="market-stat"><span>Squad size</span><b>{room.settings.squadSize} players</b></div><div className="market-stat"><span>Player pool</span><b>{room.settings.auctionPoolSize} players</b></div><div className="market-stat"><span>Current / Icon / Hero price</span><b>{room.settings.openingPriceMultipliers?`${room.settings.openingPriceMultipliers.Current}× / ${room.settings.openingPriceMultipliers.Icon}× / ${room.settings.openingPriceMultipliers.Hero}×`:'1× base price'}</b></div><p className="setup-footnote">A fresh random player selection was saved to this room. Every phone will see the same auction order.</p></aside>
      </section>:activeView==='auction'?<><section className="auction-grid">
        <section className="lot-card">
          {currentPlayer?<>
            <div className="lot-card-top"><span>PLAYER ON THE BLOCK</span><span className="lot-live"><i/>NO TIMER</span></div>
            <PlayerPanel player={currentPlayer}/>
            <div className="bid-strip bidder-highlight">
              <div className="bidder-main">
                <span className="micro-label">{highestBidTeam?'CURRENT HIGHEST BIDDER':'BIDDING IS OPEN'}</span>
                <strong className="bidder-team-name">{highestBidTeam?.teamName??'No bids yet'}</strong>
                <small>{highestBidTeam?(highestBidTeam.id===myTeam?.id?'Your team is leading this player.':'This team currently leads the auction.'):'The first contestant can bid at the opening price.'}</small>
              </div>
              <div className="bidder-live-amount"><span>LIVE BID</span><strong>{fmt(room.currentBid)}</strong><small>{highestBidTeam?'TOP OFFER':'OPENING PRICE'}</small></div>
              <div className="teams-still-in"><b>{room.activeTeamIds.length}</b><span>TEAMS<br/>STILL IN</span></div>
            </div>
            <div className="my-bid-panel">
              <div className="my-bid-title"><span>YOUR TEAM · {myTeam?.teamName}</span><b>{fmt(myTeam?.budgetRemaining??0)} LEFT</b></div>
              {myIsActive?<>
                <div className="quick-bid-panel">
                  <div className="quick-bid-heading"><b>QUICK BID</b><small>{myIsHighest?'You are leading. Wait for another team to raise.':'Current offer: '+fmt(room.currentBid)+' · choose an increase.'}</small></div>
                  {!room.highestBidderTeamId&&<button type="button" className="opening-bid-button" disabled={actionBusy||room.currentBid>(myTeam?.budgetRemaining??0)} onClick={()=>placeBid(room.currentBid)}>OPENING BID <strong>{fmt(room.currentBid)}</strong></button>}
                  <div className="quick-bid-grid">
                    {[1,10,20,50,100].map(increment=>{
                      const amount=room.currentBid+increment
                      const affordable=amount<=(myTeam?.budgetRemaining??0)
                      return <button type="button" key={increment} disabled={actionBusy||myIsHighest||!affordable} onClick={()=>placeBid(amount)}>
                        <b>+{increment}</b><small>{amount.toLocaleString('en-IN')} pts</small>
                      </button>
                    })}
                  </div>
                  <small className="quick-bid-safety">{myIsHighest?'You cannot bid against your own leading offer.':'Your maximum possible bid is '+fmt(myTeam?.budgetRemaining??0)+'.'}</small>
                </div>
                <button className="quit-button full-quit" disabled={actionBusy||myIsHighest} onClick={quitLot}>{myIsHighest?'YOU ARE LEADING · QUIT DISABLED':'QUIT THIS PLAYER'}</button>
              </>:<div className="team-out-message">{(myTeam?.purchases.length??0)>=room.settings.squadSize?'Your squad is full. You can watch the remaining auction.':'Your team has quit this player. You can watch the remaining bids, but cannot re-enter this lot.'}</div>}
              {myIsHighest&&<p className="bid-info">Your team cannot quit while it is the highest bidder. Another team must outbid you first.</p>}
            </div>
            <p className="auction-explainer">No countdown. Each contestant bids from their own phone or quits. When only the highest bidder remains, the player is sold. If everyone quits before any bid, the player is unsold.</p>
          </>:<div className="waiting-lot"><div className="gavel-mark">⚽</div><h2>{room.status==='finished'?'Auction complete':'Loading next player'}</h2><p>{room.status==='finished'?'The player queue is complete. Arrange your tactics and submit your final squad.':'The next player is revealed automatically as soon as the previous lot is sold or marked unsold.'}</p>{room.status==='finished'&&<button className="primary-button compact" onClick={()=>setActiveView('squads')}>BUILD FINAL TEAM ↗</button>}</div>}
          {currentPlayer&&<div className="lot-footer"><span>PLAYER POOL <b>{room.settings.auctionPoolSize}</b></span><span>SOLD <b>{room.teams.reduce((n,t)=>n+t.purchases.length,0)}</b></span><span>IN QUEUE <b>{room.queueCount}</b></span></div>}
        </section>
        <aside className="auction-sidebar">
          <section className="side-card"><div className="side-card-head"><span>ALL CONTESTANT TEAMS</span><small>{room.teams.length} TEAMS</small></div>
            {room.teams.map(t=><TeamRow key={t.id} team={t} room={room} isLive={room.status==='live'}/>)}
          </section>
          <section className="side-card market-card"><div className="side-card-head"><span>AUCTION RULES</span><small>ACTIVE</small></div>
            <div className="market-stat"><span>Squad size</span><b>{room.settings.squadSize}</b></div>
            <div className="market-stat"><span>Bid rule</span><b>Enter any higher whole-number bid</b></div>
            <div className="market-stat"><span>Player source</span><b>489-player database</b></div>
            <div className="market-stat"><span>Opening price</span><b>{currentPlayer?`${room.settings.openingPriceMultipliers?.[currentPlayer.category]??1}× ${currentPlayer.category} base price`:'Category-adjusted base price'}</b></div>
            <div className="market-stat"><span>Categories</span><b>Current · Icon · Hero</b></div>
          </section>
          <section className="message-card live-feed-emphasis"><span>LIVE AUCTION FEED</span><p>{room.lastMessage}</p></section>
        </aside>
      </section>
      <section className="live-team-board">
        <div className="live-team-board-head"><div><h2>All contestant squads</h2><p>Every purchase and formation remains visible to everyone in the room. Opponent teams are read-only.</p></div><span>{room.teams.length} TEAMS</span></div>
        <div className="squad-grid">{room.teams.map(t=><TeamFormationCard key={t.id} team={t} pool={room.poolPlayers} own={t.id===room.myTeamId}/>)}</div>
      </section></>:activeView==='squads'?<section className="squads-screen">
        <div className="squad-board-head"><div><h2>All teams · formation room</h2><p>Every contestant can see every formation. Only your own team can be edited from this device.</p></div></div>
        {myTeam&&<FormationEditor team={myTeam} room={room} lineup={editingLineup} disabled={myTeam.submitted||actionBusy} onMove={movePlayer} onRole={changePlayerRole} onRemove={removePlayerFromXI} onSave={saveFormation} onSubmit={submitTeam} busy={actionBusy}/>}
        <div className="squad-grid">{room.teams.map(t=><TeamFormationCard key={t.id} team={t} pool={room.poolPlayers} own={t.id===room.myTeamId}/>)}</div>
      </section>:<ResultsScreen room={room} results={results} allTeamsSubmitted={allTeamsSubmitted} onGoToSquads={()=>setActiveView('squads')}/>}
    </>}
  </Shell>
}

function ResultsScreen({room,results,allTeamsSubmitted,onGoToSquads}:{room:RoomState;results:TeamResult[];allTeamsSubmitted:boolean;onGoToSquads:()=>void}){
  if(!allTeamsSubmitted){
    const submitted=room.teams.filter(t=>t.isSeated&&t.submitted).length
    const seated=room.teams.filter(t=>t.isSeated).length
    return <section className="results-locked">
      <div className="results-lock-icon">🏆</div>
      <span className="micro-label">FINAL STANDINGS LOCKED</span>
      <h2>Waiting for every team to submit.</h2>
      <p>The auction is over, but the results will be revealed only after every contestant has submitted their own tactical setup.</p>
      <div className="submission-progress"><div><b>{submitted}/{seated}</b><small>FINAL TEAMS SUBMITTED</small></div><div className="submission-track"><i style={{width:`${seated?submitted/seated*100:0}%`}}/></div></div>
      <div className="submission-list">{room.teams.filter(t=>t.isSeated).map(team=><div key={team.id}><span>{team.teamName}</span><b className={team.submitted?'submitted-tag':'waiting-tag'}>{team.submitted?'SUBMITTED':'WAITING'}</b></div>)}</div>
      <div className="results-locked-actions">
        {room.teams.find(t=>t.id===room.myTeamId)?.submitted
          ? <span className="submitted-tag">YOUR TEAM IS SUBMITTED — WAITING FOR OTHERS</span>
          : <button className="primary-button compact" onClick={onGoToSquads}>GO TO SQUADS & SUBMIT ↗</button>}
        <button className="quiet-button" onClick={()=>window.location.reload()}>REFRESH STATUS</button>
      </div>
    </section>
  }
  if(results.length===0)return <section className="results-locked"><div className="results-lock-icon">⚽</div><h2>No contestant squads found.</h2><p>There are no seated teams to rank in this room.</p></section>

  const champion=results[0]
  const podium=results.filter(r=>r.rank<=3)
  const medalFor=(rank:number)=>rank===1?'🏆':rank===2?'🥈':rank===3?'🥉':'⚽'
  const championRunner=results[1]
  const metrics=champion.metrics
  const maxScore=Math.max(...results.map(r=>r.score),1)

  return <section className="results-screen">
    <div className="results-intro">
      <span className="micro-label">THE AUCTION IS OVER · FINAL TACTICS LOCKED</span>
      <h2>Final standings, backed by squad analysis.</h2>
      <p>FootBid compares the five criteria you selected. The breakdown below shows what separated the winner from the other teams.</p>
    </div>
    <section className="champion-card">
      <div className="champion-spark">✦</div>
      <div className="champion-kicker"><span>🏆</span> FOOTBID CHAMPIONS</div>
      <div className="champion-name">{champion.team.teamName}</div>
      <div className="champion-subtitle">1ST PLACE · HIGHEST SQUAD ANALYSIS SCORE</div>
      <div className="champion-score"><strong>{champion.score.toFixed(1)}</strong><small>/ 100</small></div>
      <div className="champion-meta"><span>{champion.team.purchases.length}/{room.settings.squadSize} squad players</span><span>{champion.startingPlayers.length}/11 starters set</span><span>{champion.benchPlayers.length} on bench</span></div>
      <div className="champion-confetti" aria-hidden="true">✦　✧　✦　✧　✦</div>
    </section>

    <section className="winner-explanation">
      <div className="winner-explanation-title"><span className="micro-label">WHY {champion.team.teamName.toUpperCase()} FINISHED FIRST</span><h3>The decisive advantage</h3></div>
      <p>{champion.primaryReason}</p>
      {championRunner&&<p className="comparison-context">Overall lead: <b>{(champion.score-championRunner.score).toFixed(1)} points</b> over {championRunner.team.teamName}. This is the score difference after applying all five weighted criteria.</p>}
      <div className="winner-factor-grid">
        {champion.metrics.slice().sort((a,b)=>(b.score*b.weight)-(a.score*a.weight)).slice(0,2).map(metric=><div key={metric.key}><b>{metric.weight}%</b><span>{metric.title}</span><strong>{metric.score.toFixed(1)}/100</strong></div>)}
      </div>
    </section>

    <div className="podium-heading"><div><span className="micro-label">THE PODIUM</span><h3>Top {Math.min(3,results.length)} teams</h3></div><span>{results.length} CONTESTANT TEAMS RANKED</span></div>
    <div className="podium-grid">
      {podium.map(result=><article className={`podium-card rank-${result.rank}`} key={result.team.id}>
        <div className="podium-medal">{medalFor(result.rank)}</div>
        <span className="podium-position">{result.rank===1?'1ST PLACE · WINNER':result.rank===2?'2ND PLACE · RUNNER-UP':result.rank===3?'3RD PLACE':'JOINT PLACE'}</span>
        <h3>{result.team.teamName}</h3>
        <strong className="podium-score">{result.score.toFixed(1)}<small>/100</small></strong>
        <p>{result.team.purchases.length}/{room.settings.squadSize} players · {result.startingPlayers.length}/11 placed</p>
        <div className="podium-reason">{result.primaryReason}</div>
        <div className="podium-detail"><span>Starting XI</span><b>{result.metrics[0].score.toFixed(1)}</b></div>
        <div className="podium-detail"><span>Bench</span><b>{result.metrics[1].score.toFixed(1)}</b></div>
        <div className="podium-detail"><span>Player mix</span><b>{result.metrics[2].score.toFixed(1)}</b></div>
      </article>)}
    </div>

    <section className="comparison-card">
      <div className="standings-head"><div><span className="micro-label">HEAD-TO-HEAD BREAKDOWN</span><h3>What each team scored</h3></div><span>CRITERION SCORES / 100</span></div>
      <div className="comparison-legend"><span>Higher bars mean a stronger result in that criterion.</span><span>Weight is applied to the final score.</span></div>
      {metrics.map(metric=><div className="metric-comparison" key={metric.key}>
        <div className="metric-comparison-head"><b>{metric.title}</b><span>{metric.weight}% of final score</span></div>
        {results.map(result=>{
          const value=result.metrics.find(m=>m.key===metric.key)?.score??0
          return <div className="metric-team-row" key={result.team.id}>
            <span>{result.team.teamName}</span>
            <div className="metric-track"><i style={{width:`${value}%`}} className={result.rank===1?'metric-winner':''}/></div>
            <b>{value.toFixed(1)}</b>
          </div>
        })}
      </div>)}
    </section>

    <section className="position-fit-analysis">
      <div className="standings-head"><div><span className="micro-label">POSITIONAL IMPACT</span><h3>Who played out of position?</h3></div><span>POSITION FIT AFFECTS XI + TACTICAL SCORES</span></div>
      <p className="position-fit-intro">You can place any player anywhere on the pitch. The analysis compares the assigned role with the player's listed database positions. A goalkeeper at CF is allowed, but receives a very low fit score and reduces the team's Starting XI and Tactical Balance marks.</p>
      <div className="position-fit-grid">{results.map(result=>{
        const mismatches=result.positionAnalysis.filter(item=>item.suitability<99).sort((a,b)=>a.suitability-b.suitability)
        return <article className="position-fit-team" key={result.team.id}>
          <div className="position-fit-team-head"><b>{result.team.teamName}</b><span>{result.positionAnalysis.filter(item=>item.suitability>=99).length}/{result.positionAnalysis.length} natural fits</span></div>
          {mismatches.length===0?<p className="position-fit-none">All selected starters match their natural database positions.</p>:<div className="position-fit-list">{mismatches.slice(0,5).map(item=><div className="position-fit-row" key={item.player.id}>
            <span className="position-fit-player">{item.player.name}<small>{item.player.position.join(' / ')} → {item.role}</small></span>
            <span className={`position-fit-score ${item.suitability<30?'severe-fit':''}`}>{item.suitability}% fit</span>
          </div>)}</div>}
          {mismatches.length>5&&<small className="position-fit-more">+ {mismatches.length-5} more out-of-position players</small>}
        </article>
      })}</div>
    </section>

    <section className="standings-card">
      <div className="standings-head"><div><span className="micro-label">FINAL LEADERBOARD</span><h3>All team standings</h3></div><span>RANKED BY FIVE CRITERIA</span></div>
      <div className="standings-table">
        <div className="standings-row standings-header"><span>RANK</span><span>TEAM</span><span>SQUAD</span><span>SCORE</span></div>
        {results.map(result=><div className={`standings-row ${result.rank===1?'standing-winner':''}`} key={result.team.id}>
          <span className="standing-rank">{medalFor(result.rank)} <b>#{result.rank}</b></span>
          <span className="standing-team"><b>{result.team.teamName}</b><small>{result.startingPlayers.length}/11 XI · {result.benchPlayers.length} bench</small></span>
          <span className="standing-squad">{result.team.purchases.length}/{room.settings.squadSize}</span>
          <strong className="standing-score">{result.score.toFixed(1)}</strong>
        </div>)}
      </div>
    </section>

    <section className="score-method">
      <div><span className="micro-label">SCORING METHOD</span><h3>Your five winning criteria</h3><p>Every team is scored using the same model. The percentage is the weight each criterion contributes to the final 100-point score.</p></div>
      <div className="score-method-grid">
        {metrics.map(metric=><div key={metric.key}><b>{metric.weight}%</b><span>{metric.title}</span><small>{metric.detail}</small></div>)}
      </div>
      <p className="score-disclaimer">Dataset limitation: the supplied 489-player file provides category, base_price and listed positions, but not technical attributes, match ratings or player statistics. Starting XI and bench strength therefore use the dataset base_price as a strength proxy, then apply a strong penalty to out-of-position assignments. A goalkeeper used at CF is permitted but receives a very low positional-fit score. This is a FootBid game model, not a real-world player rating or match prediction.</p>
    </section>
    <div className="results-actions"><button className="quiet-button" onClick={()=>window.print()}>PRINT RESULTS</button><button className="primary-button compact" onClick={()=>navigator.clipboard?.writeText(`FootBid Results — Room ${room.code}\n${results.map(r=>`#${r.rank} ${r.team.teamName}: ${r.score.toFixed(1)}/100 — ${r.primaryReason}`).join('\n')}`)}>COPY RESULTS & EXPLANATION ↗</button></div>
  </section>
}

function Shell({children}:{children:ReactNode}){
  return <div className="app-shell"><header className="topbar"><div className="brand-lockup"><div className="brand-symbol">FB</div><div className="brand-name">FOOT<span>BID</span><small>THE FOOTBALL AUCTION GAME</small></div></div><div className="topbar-right"><span className="mode-pill"><i/> MULTIPLAYER ROOMS</span></div></header><main className="main-wrap">{children}</main><footer className="site-footer"><span>FOOTBID <b>© 2026</b></span><span>BUILD YOUR LEGACY. ONE BID AT A TIME.</span></footer></div>
}
function PlayerPanel({player}:{player:Player}){
  return <div className="player-hero dataset-player-hero">
    <div className="player-image-wrap">
      {player.image?<img src={player.image} alt={player.name} loading="lazy"/>:<div className="player-image-fallback">{player.name.split(' ').map(w=>w[0]).join('').slice(0,2)}</div>}
      <span className={`player-category-badge category-${player.category.toLowerCase()}`}>{categoryLabel(player.category)}</span>
    </div>
    <div className="player-detail">
      <span className={`category-tag category-${player.category.toLowerCase()}`}>{player.category.toUpperCase()}</span>
      <h2>{player.name}</h2>
      <p className="player-best-known">{player.best_known_for}</p>
      <div className="prime-row">DATABASE POSITIONS <b>{player.position.join(' · ')}</b></div>
      <div className="position-row"><span>AUCTION BASE PRICE</span><b>{fmt(player.base_price)}</b><span>CATEGORY</span><b>{player.category.toUpperCase()}</b></div>
      <div className="player-attribution"><a href={player.image_file_page_url||player.image_attribution_url} target="_blank" rel="noreferrer">Image source & licence details</a></div>
    </div>
  </div>
}
function HostKickControls({room,onKick}:{room:RoomState;onKick:(teamId:string,teamName:string)=>void}){
  const contestants=room.teams.filter(team=>team.isSeated&&!team.isMine)
  if(!room.isHost||contestants.length===0)return null
  return <section className="host-management-card">
    <div><span className="micro-label">HOST CONTROLS</span><b>Manage contestants</b><small>Remove a disconnected or withdrawn contestant. Their team and seat are removed so the auction can continue.</small></div>
    <div className="host-kick-list">{contestants.map(team=><div key={team.id}><span>{team.teamName}</span><button type="button" onClick={()=>onKick(team.id,team.teamName)}>KICK OUT</button></div>)}</div>
  </section>
}
function TeamRow({team,room,isLive}:{team:Team;room:RoomState;isLive:boolean}){
  const active=room.activeTeamIds.includes(team.id)
  const leading=room.highestBidderTeamId===team.id
  const status=isLive?(leading?'HIGHEST BIDDER':team.purchases.length>=room.settings.squadSize?'SQUAD FULL':active?'IN THE LOT':'QUIT THIS LOT'):team.isSeated?'JOINED':'WAITING'
  return <div className={`team-purse-wrap ${isLive&&!active?'team-passed':''}`}><div className="team-purse"><span className="team-avatar">{team.teamName.slice(0,1)}</span><span className="team-purse-main"><b>{team.teamName} {team.isMine&&<em>YOU</em>}</b><small>{team.purchases.length}/{room.settings.squadSize} players · {status}</small></span><strong>{team.budgetRemaining}<small>PTS</small></strong></div></div>
}
function FormationEditor({team,room,lineup,disabled,onMove,onRole,onRemove,onSave,onSubmit,busy}:{team:Team;room:RoomState;lineup:PlayerPlacement[];disabled:boolean;onMove:(id:string,x:number,y:number)=>void;onRole:(id:string,role:TacticalRole)=>void;onRemove:(id:string)=>void;onSave:()=>void;onSubmit:()=>void;busy:boolean}){
  const [selectedId,setSelectedId]=useState('')
  const owned=team.purchases.map(p=>getPlayer(p.playerId,room.poolPlayers)).filter((p):p is Player=>Boolean(p))
  const placedIds=new Set(lineup.map(p=>p.playerId))
  const bench=owned.filter(player=>!placedIds.has(player.id))
  function positionFromEvent(event:{clientX:number;clientY:number;currentTarget:HTMLElement}){
    const rect=event.currentTarget.getBoundingClientRect()
    return {
      x:Math.max(4,Math.min(96,((event.clientX-rect.left)/rect.width)*100)),
      y:Math.max(4,Math.min(96,((event.clientY-rect.top)/rect.height)*100))
    }
  }
  function handleDrop(event:DragEvent<HTMLDivElement>){
    event.preventDefault()
    if(disabled)return
    const playerId=event.dataTransfer.getData('text/plain')
    if(!playerId)return
    const point=positionFromEvent(event)
    onMove(playerId,point.x,point.y)
    setSelectedId('')
  }
  function handlePitchClick(event:MouseEvent<HTMLDivElement>){
    if(disabled||!selectedId)return
    const point=positionFromEvent(event)
    onMove(selectedId,point.x,point.y)
    setSelectedId('')
  }
  function dragPlayer(event:DragEvent,playerId:string){
    event.dataTransfer.setData('text/plain',playerId)
    event.dataTransfer.effectAllowed='move'
    setSelectedId(playerId)
  }
  return <section className="formation-editor">
    <div className="formation-editor-head">
      <div><span className="micro-label">YOUR TEAM · TACTICAL BUILDER</span><h3>{team.teamName} · {formationLabel(lineup)}</h3>
        <p>Move a player anywhere on the pitch: their role changes automatically from that zone. You can also choose any tactical role manually. Natural positions are marked in the list; playing out of position is allowed but reduces the squad score.</p>
      </div>
      <span className={team.submitted?'submitted-pill':'editing-pill'}>{team.submitted?'FINAL TEAM SUBMITTED':'YOUR TEAM · EDITABLE'}</span>
    </div>
    <div className="formation-controls custom-formation-controls">
      <div className="formation-progress"><b>{owned.length}/{room.settings.squadSize}</b><small>SQUAD PLAYERS</small></div>
      <div className="formation-progress"><b>{lineup.length}/11</b><small>STARTING XI POSITIONS</small></div>
      <div className="formation-progress"><b>{bench.length}</b><small>BENCH PLAYERS</small></div>
    </div>
    <div className={`tactical-pitch movable-pitch ${selectedId?'pitch-select-mode':''}`} onDragOver={e=>e.preventDefault()} onDrop={handleDrop} onClick={handlePitchClick}>
      <div className="pitch-center-line"/><div className="pitch-center-circle"/>
      <div className="pitch-box pitch-top-box"/><div className="pitch-box pitch-bottom-box"/>
      <span className="pitch-direction-label pitch-att-label">ATTACK</span><span className="pitch-direction-label pitch-def-label">YOUR GOAL</span>
      {lineup.map(placement=>{
        const player=getPlayer(placement.playerId,room.poolPlayers)
        if(!player)return null
        return <button type="button" className={`pitch-token ${selectedId===player.id?'selected-token':''}`} key={player.id}
          draggable={!disabled} onDragStart={e=>dragPlayer(e,player.id)}
          onClick={e=>{e.stopPropagation();setSelectedId(player.id)}}
          style={{left:`${placement.x}%`,top:`${placement.y}%`}} title={`${player.name} · ${placement.role} — drag to move`}>
          <b>{placement.role}</b><span>{player.name.split(' ').map(w=>w[0]).join('').slice(0,2).toUpperCase()}</span><small>{player.name}</small>
        </button>
      })}
      {selectedId&&<div className="pitch-hint">Tap a new pitch location to move {getPlayer(selectedId,room.poolPlayers)?.name}</div>}
    </div>
    <div className="placed-xi-section">
      <div className="bench-heading"><div><b>STARTING XI · TACTICAL ROLES</b><small>All roles are available. Natural positions are shown in the dropdown; an out-of-position assignment is allowed and scored accordingly.</small></div><span>{lineup.length}/11</span></div>
      {lineup.length===0?<div className="empty-xi">No players on the pitch yet. Add a player from your squad list below.</div>:
        <div className="placed-xi-list">{lineup.map(placement=>{
          const player=getPlayer(placement.playerId,room.poolPlayers)
          if(!player)return null
          const options=eligibleRoles(player)
          return <div className="placed-xi-row" key={player.id}>
            <img src={player.image} alt="" loading="lazy"/>
            <div className="placed-player-info"><b>{player.name}</b><small>{player.position.join(' / ')} · {player.category}</small></div>
            <select value={placement.role} disabled={disabled} onChange={e=>onRole(player.id,e.target.value as TacticalRole)}>
              {tacticalRoles.map(role=><option key={role} value={role}>{role} — {roleLabel[role]}{options.includes(role)?' · NATURAL':' · OUT OF POSITION'}</option>)}
            </select>
            <button type="button" className="remove-placement" disabled={disabled} onClick={()=>onRemove(player.id)}>REMOVE</button>
          </div>
        })}</div>}
    </div>
    <div className="bench-row bench-row-flex">
      <div className="bench-heading"><div><b>BENCH / AVAILABLE PLAYERS</b><small>Drag onto the pitch, select then tap a location, or use ADD TO XI.</small></div><span>{bench.length} AVAILABLE</span></div>
      <div className="bench-list dataset-bench-list">
        {bench.map(player=><div className={`bench-player-card ${selectedId===player.id?'selected-bench-player':''}`} key={player.id}>
          <button type="button" draggable={!disabled} onDragStart={e=>dragPlayer(e,player.id)} onClick={()=>setSelectedId(player.id)} disabled={disabled}>
            <img src={player.image} alt="" loading="lazy"/>
            <span><b>{player.name}</b><small>{player.position.join(' / ')} · {player.category}</small></span>
          </button>
          <button type="button" className="add-to-xi" disabled={disabled||lineup.length>=11} onClick={()=>{
            const role=defaultRole(player)
            const base=roleInitialPosition[role]
            const sameRole=lineup.filter(item=>item.role===role).length
            const offset=sameRole%2===0?sameRole*5:-sameRole*5
            onMove(player.id,Math.max(8,Math.min(92,base.x+offset)),Math.max(8,Math.min(92,base.y+Math.floor(sameRole/2)*4)))
          }}>ADD</button>
        </div>)}
        {bench.length===0&&<span className="bench-empty">No players left on the bench.</span>}
      </div>
    </div>
    <div className="formation-submit-row">
      <p>{room.status==='finished'?'Auction ended. Review your starting XI and bench, then submit your final tactics.':'You can reposition players and change roles while the auction is active.'}</p>
      <div className="formation-actions">
        <button className="quiet-button" disabled={disabled||busy} onClick={onSave}>SAVE TACTICS</button>
        <button className="primary-button compact" disabled={room.status!=='finished'||team.submitted||busy} onClick={onSubmit}>{team.submitted?'TEAM SUBMITTED':'SUBMIT FINAL TEAM ↗'}</button>
      </div>
    </div>
  </section>
}
function MiniTacticalPitch({team,pool}:{team:Team;pool:Player[]}){
  return <div className="mini-tactical-pitch">
    <div className="pitch-center-line"/><div className="pitch-center-circle"/>
    {team.lineup.map(placement=>{
      const player=getPlayer(placement.playerId,pool)
      if(!player)return null
      return <div className="mini-pitch-token" key={player.id} style={{left:`${placement.x}%`,top:`${placement.y}%`}}>
        <b>{placement.role}</b><small>{player.name.split(' ').map(w=>w[0]).join('').slice(0,2).toUpperCase()}</small>
      </div>
    })}
  </div>
}
function TeamFormationCard({team,pool,own}:{team:Team;pool:Player[];own:boolean}){
  const placedIds=new Set(team.lineup.map(p=>p.playerId))
  const starters=team.lineup.map(p=>getPlayer(p.playerId,pool)).filter((p):p is Player=>Boolean(p))
  const bench=team.purchases.filter(p=>!placedIds.has(p.playerId)).map(p=>getPlayer(p.playerId,pool)).filter((p):p is Player=>Boolean(p))
  return <article className={`team-squad-card ${own?'own-team-card':''}`}>
    <div className="team-squad-head">
      <div className="team-avatar large">{team.teamName.slice(0,1)}</div>
      <div><h3>{team.teamName} {own&&<em>YOU</em>}</h3><p>{team.purchases.length} players · {formationLabel(team.lineup)}</p><small className={team.submitted?'submitted-tag':'not-submitted-tag'}>{team.submitted?'SUBMITTED':'FORMATION VISIBLE · READ ONLY'}</small></div>
      <strong>{fmt(team.budgetRemaining)}<small> LEFT</small></strong>
    </div>
    <MiniTacticalPitch team={team} pool={pool}/>
    <div className="roster-category-counts">
      <span>XI <b>{starters.length}</b></span><span>BENCH <b>{bench.length}</b></span>
      <span>CURRENT <b>{team.purchases.filter(p=>getPlayer(p.playerId,pool)?.category==='Current').length}</b></span>
      <span>ICON <b>{team.purchases.filter(p=>getPlayer(p.playerId,pool)?.category==='Icon').length}</b></span>
      <span>HERO <b>{team.purchases.filter(p=>getPlayer(p.playerId,pool)?.category==='Hero').length}</b></span>
    </div>
    <div className="purchased-list">{team.purchases.map(p=>{
      const player=getPlayer(p.playerId,pool)
      if(!player)return null
      return <div className="purchased-player" key={p.playerId}>
        {player.image?<img className="player-initial-small roster-player-image" src={player.image} alt="" loading="lazy"/>:<span className="player-initial-small">{player.name.slice(0,2).toUpperCase()}</span>}
        <span className="purchased-name"><b>{player.name}</b><small>{player.position.join(' / ')} · {player.category}</small></span>
        <strong>{fmt(p.price)}</strong>
      </div>
    })}</div>
  </article>
}
export default App
