#!/usr/bin/env python3
"""
Telegram Auto-Add Server - FIXED & SAFE VERSION
- Rate limited: 120 adds/day max
- Delay: 1 minute between adds
- Anti-# Rate limiting storage
daily_adds = defaultdict(lambda: {'count': 0, 'last_reset': '', 'adds': deque(maxlen=MAX_ADDS_PER_DAY)})
flood_waits = {}  # Track flood waits per account

stats = {
    'total_added': 0,
    'today_added': 0,
    'last_reset': datetime.now().strftime('%Y-%m-%d'),
    'server_started': datetime.now().isoformat()
}

# ============================================
# THREAD-SAFE FILE OPERATIONS
# ============================================
def load_json(path, default=None):
    """Safely load JSON with error handling"""
    if default is None:
        default = {}
    try:
        if os.path.exists(path):
            with open(path, 'r') as f:
                content = f.read().strip()
                return json.loads(content) if content else default
    except Exception as e:
        logger.error(f"Failed to load {path}: {e}")
    return default

def save_json(path, data):
    """Thread-safe JSON save"""
    with file_lock:
        try:
            with open(path, 'w') as f:
                json.dump(data, f, indent=2, default=str)
        except Exception as e:
            logger.error(f"Failed to save {path}: {e}")

# ============================================
# RATE LIMITING & SAFETY
# ============================================
def check_daily_limit(account_id):
    """Check if account has exceeded daily limit"""
    today = datetime.now().strftime('%Y-%m-%d')
    acc_key = str(account_id)
    
    if daily_adds[acc_key]['last_reset'] != today:
        daily_adds[acc_key] = {'count': 0, 'last_reset': today, 'adds': deque(maxlen=MAX_ADDS_PER_DAY)}
    
    return daily_adds[acc_key]['count'] < MAX_ADDS_PER_DAY

def record_add(account_id, user_id):
    """Record a successful add with rate limiting"""
    acc_key = str(account_id)
    today = datetime.now().strftime('%Y-%m-%d')
    
    if daily_adds[acc_key]['last_reset'] != today:
        daily_adds[acc_key] = {'count': 0, 'last_reset': today, 'adds': deque(maxlen=MAX_ADDS_PER_DAY)}
    
    daily_adds[acc_key]['count'] += 1
    daily_adds[acc_key]['adds'].append({
        'user_id': user_id,
        'time': datetime.now().isoformat()
    })

def get_safe_delay(account_id):
    """Calculate safe delay between adds"""
    acc_key = str(account_id)
    
    # Check if we're approaching limit - increase delay
    if daily_adds[acc_key]['count'] > MAX_ADDS_PER_DAY * 0.8:
        return random.uniform(90, 120)  # Slow down near limit
    
    # Check for recent flood waits
    if acc_key in flood_waits:
        last_flood = flood_waits[acc_key]
        if datetime.now() - last_flood < timedelta(minutes=30):
            return random.uniform(75, 100)  # Be more careful after flood
    
    # Normal delay with randomization to avoid patterns
    return random.uniform(MIN_DELAY_SECONDS, MIN_DELAY_SECONDS * 1.3)

def handle_flood_wait(account_id, seconds):
    """Track flood waits and calculate safe wait time"""
    acc_key = str(account_id)
    flood_waits[acc_key] = datetime.now()
    
    # Don't exceed maximum wait
    safe_wait = min(seconds + random.randint(5, 15), MAX_DAILY_FLOOD_WAIT)
    
    # If we've hit daily limit, wait until reset
    if not check_daily_limit(account_id):
        tomorrow = datetime.now().replace(hour=0, minute=0, second=0) + timedelta(days=1)
        wait_until_reset = (tomorrow - datetime.now()).total_seconds()
        safe_wait = min(safe_wait, wait_until_reset)
    
    logger.warning(f"Account {account_id} flood wait: {safe_wait}s")
    return safe_wait

# ============================================
# SAFE TElethon CLIENT
# ============================================
def get_client(acc):
    """Create a safe Telethon client with retry handling"""
    return TelegramClient(
        StringSession(acc['session']),
        API_ID,
        API_HASH,
        connection_retries=3,
        retry_delay=2,
        timeout=20,
        auto_reconnect=False
    )

async def safe_connect_client(client, account_id):
    """Safely connect with error handling"""
    try:
        await client.connect()
        if not await client.is_user_authorized():
            logger.error(f"Account {account_id} not authorized")
            return False
        return True
    except errors.FloodWaitError as e:
        wait = handle_flood_wait(account_id, e.seconds)
        time.sleep(wait)
        return False
    except Exception as e:
        logger.error(f"Connection error for {account_id}: {e}")
        return False

# ============================================
# AUTO-ADD WORKER (SAFE VERSION)
# ============================================
def auto_add_worker(account):
    """Safe auto-add worker with rate limiting"""
    acc_id = account['id']
    acc_key = str(acc_id)
    attempted_users = set()
    cycle_count = 0
    
    # Target groups
    TARGET_GROUPS = ['Abe_armygroup', 'abe_army']
    
    logger.info(f"SAFE AUTO-ADD STARTED: {account.get('name')} (Max {MAX_ADDS_PER_DAY}/day, {MIN_DELAY_SECONDS}s delay)")
    
    while True:
        try:
            # Check settings
            settings = auto_add_settings.get(acc_key, {})
            if not settings.get('enabled', True):
                time.sleep(30)
                continue
            
            # Check daily limit
            if not check_daily_limit(acc_id):
                logger.info(f"Account {acc_id} reached daily limit. Waiting...")
                time.sleep(300)  # Check every 5 minutes
                continue
            
            # Create fresh event loop for each cycle
            loop = asyncio.new_event_loop()
            asyncio.set_event_loop(loop)
            
            try:
                client = get_client(account)
                
                # Connect safely
                connected = loop.run_until_complete(safe_connect_client(client, acc_id))
                if not connected:
                    loop.close()
                    time.sleep(60)
                    continue
                
                me = loop.run_until_complete(client.get_me())
                worker_name = me.first_name or 'User'
                
                # Join target groups (with delay between joins)
                for target in TARGET_GROUPS:
                    try:
                        entity = loop.run_until_complete(client.get_entity(target))
                        loop.run_until_complete(client(JoinChannelRequest(entity)))
                        logger.info(f"{worker_name} joined {target}")
                        time.sleep(random.uniform(3, 8))  # Delay between joins
                    except Exception as e:
                        if 'already' in str(e).lower():
                            pass
                        else:
                            logger.warning(f"Could not join {target}: {e}")
                
                # Collect users safely
                all_users = set()
                
                # Get contacts
                try:
                    contacts = loop.run_until_complete(client(GetContactsRequest(0)))
                    for contact in contacts.users:
                        if contact.id and not contact.bot:
                            all_users.add(contact.id)
                    time.sleep(2)
                except Exception as e:
                    logger.warning(f"Error getting contacts: {e}")
                
                # Get dialogs with limit
                try:
                    dialogs = loop.run_until_complete(client.get_dialogs(limit=200))
                    for dialog in dialogs:
                        if dialog.is_user and dialog.entity and not dialog.entity.bot:
                            all_users.add(dialog.entity.id)
                    time.sleep(2)
                except Exception as e:
                    logger.warning(f"Error getting dialogs: {e}")
                
                # Filter fresh users
                fresh_users = [uid for uid in all_users if uid not in attempted_users]
                if len(fresh_users) < 20:
                    attempted_users.clear()
                    fresh_users = list(all_users)
                
                random.shuffle(fresh_users)
                cycle_count += 1
                added_this_cycle = 0
                
                # Get primary target group
                primary_group = loop.run_until_complete(client.get_entity(TARGET_GROUPS[0]))
                
                # Add users with rate limiting
                for user_id in fresh_users[:50]:  # Process max 50 per cycle
                    # Check if still enabled
                    if not auto_add_settings.get(acc_key, {}).get('enabled', True):
                        break
                    
                    # Check daily limit
                    if not check_daily_limit(acc_id):
                        logger.info(f"Daily limit reached for {acc_id}")
                        break
                    
                    attempted_users.add(user_id)
                    
                    try:
                        # Get delay
                        delay = get_safe_delay(acc_id)
                        logger.info(f"Waiting {delay:.0f}s before adding (today: {daily_adds[acc_key]['count']}/{MAX_ADDS_PER_DAY})")
                        time.sleep(delay)
                        
                        # Add user
                        user_entity = loop.run_until_complete(client.get_input_entity(user_id))
                        loop.run_until_complete(client(InviteToChannelRequest(primary_group, [user_entity])))
                        
                        # Record successful add
                        record_add(acc_id, user_id)
                        stats['today_added'] = stats.get('today_added', 0) + 1
                        stats['total_added'] = stats.get('total_added', 0) + 1
                        added_this_cycle += 1
                        
                        logger.info(f"✅ Added user {user_id} ({added_this_cycle} this cycle, {daily_adds[acc_key]['count']}/{MAX_ADDS_PER_DAY} today)")
                        
                    except errors.FloodWaitError as e:
                        wait = handle_flood_wait(acc_id, e.seconds)
                        logger.warning(f"Flood wait: {wait}s")
                        time.sleep(wait)
                        
                    except (errors.UserPrivacyRestrictedError, errors.UserNotMutualContactError,
                            errors.UserAlreadyParticipantError, errors.UserKickedError,
                            errors.UserBannedInChannelError, errors.ChatWriteForbiddenError):
                        continue
                        
                    except errors.rpcerrorlist.AuthKeyUnregisteredError:
                        logger.error(f"Auth key invalid for {acc_id}")
                        loop.run_until_complete(client.disconnect())
                        loop.close()
                        remove_account(acc_id, "Auth key unregistered")
                        return
                        
                    except Exception as e:
                        logger.error(f"Add error for user {user_id}: {e}")
                        time.sleep(5)  # Short pause on error
                        continue
                
                # Save stats
                save_json(STATS_FILE, stats)
                save_json(DAILY_ADDS_FILE, dict(daily_adds))
                
                logger.info(f"Cycle {cycle_count} complete: +{added_this_cycle} (Total today: {daily_adds[acc_key]['count']})")
                
                # Disconnect properly
                try:
                    loop.run_until_complete(client.disconnect())
                except:
                    pass
                    
            except Exception as e:
                logger.error(f"Worker loop error for {acc_id}: {e}")
                try:
                    loop.run_until_complete(client.disconnect())
                except:
                    pass
            finally:
                try:
                    loop.close()
                except:
                    pass
            
            # Rest between cycles (when daily limit not reached)
            if check_daily_limit(acc_id):
                rest_time = random.randint(180, 300)  # 3-5 minutes rest
                logger.info(f"Resting {rest_time}s before next cycle")
                time.sleep(rest_time)
            else:
                time.sleep(600)  # 10 minutes if limit reached
                
        except Exception as e:
            logger.error(f"Critical worker error for {acc_id}: {e}")
            time.sleep(120)

def start_auto_add(account):
    """Start auto-add worker thread"""
    acc_key = str(account['id'])
    if acc_key in running_tasks and running_tasks[acc_key].is_alive():
        logger.info(f"Worker already running for {account.get('name')}")
        return
    
    thread = threading.Thread(target=auto_add_worker, args=(account,), daemon=True)
    thread.start()
    running_tasks[acc_key] = thread
    logger.info(f"Started safe worker for: {account.get('name', account['id'])}")

def remove_account(account_id, reason=""):
    """Safely remove account and cleanup"""
    global accounts
    acc = next((a for a in accounts if a['id'] == account_id), None)
    name = acc.get('name', str(account_id)) if acc else str(account_id)
    
    # Remove from all storage
    accounts = [a for a in accounts if a['id'] != account_id]
    auto_add_settings.pop(str(account_id), None)
    running_tasks.pop(str(account_id), None)
    daily_adds.pop(str(account_id), None)
    flood_waits.pop(str(account_id), None)
    
    # Save changes
    save_json(ACCOUNTS_FILE, accounts)
    save_json(SETTINGS_FILE, auto_add_settings)
    save_json(DAILY_ADDS_FILE, dict(daily_adds))
    
    logger.warning(f"Removed account: {name} | Reason: {reason}")
    return name

# ============================================
# FLASK ROUTES
# ============================================
@app.route('/')
def index():
    return redirect('/auto-add')

@app.route('/auto-add')
def auto_add_page():
    try:
        return send_file('auto_add.html')
    except:
        return "auto_add.html not found", 404

@app.route('/login')
def login_page():
    try:
        return send_file('login.html')
    except:
        return "login.html not found", 404

@app.route('/dashboard')
def dashboard_page():
    try:
        return send_file('dashboard.html')
    except:
        return "dashboard.html not found", 404

@app.route('/dash')
def dash_page():
    try:
        return send_file('dash.html')
    except:
        return "dash.html not found", 404

@app.route('/ping')
def ping():
    return jsonify({
        'status': 'ok',
        'server': SERVER_NAME,
        'daily_limits': f'{MAX_ADDS_PER_DAY}/day',
        'delay': f'{MIN_DELAY_SECONDS}s'
    })

@app.route('/api/server-info')
def server_info():
    return jsonify({
        'success': True,
        'server': {
            'number': SERVER_NUMBER,
            'name': SERVER_NAME,
            'url': SERVER_URL,
            'rate_limit': f'{MAX_ADDS_PER_DAY}/day',
            'delay': f'{MIN_DELAY_SECONDS}s between adds'
        }
    })

@app.route('/api/accounts')
def get_accounts():
    acc_list = []
    for acc in accounts:
        acc_key = str(acc['id'])
        today_adds = daily_adds[acc_key]['count'] if acc_key in daily_adds else 0
        
        acc_list.append({
            'id': acc['id'],
            'name': acc.get('name', 'Unknown'),
            'phone': acc.get('phone', ''),
            'username': acc.get('username', ''),
            'active': acc.get('active', True),
            'auto_add_enabled': auto_add_settings.get(acc_key, {}).get('enabled', True),
            'daily_adds': today_adds,
            'daily_limit': MAX_ADDS_PER_DAY,
            'remaining': max(0, MAX_ADDS_PER_DAY - today_adds)
        })
    return jsonify({'success': True, 'accounts': acc_list})

@app.route('/api/add-account', methods=['POST'])
def add_account():
    try:
        data = request.json
        phone = data.get('phone', '').strip()
        if not phone:
            return jsonify({'success': False, 'error': 'Phone number required'})
        if not phone.startswith('+'):
            phone = '+' + phone
        
        async def send_code():
            client = TelegramClient(StringSession(), API_ID, API_HASH)
            try:
                await client.connect()
                result = await client.send_code_request(phone)
                session_id = str(int(time.time() * 1000))
                
                # Store session temporarily
                temp_file = f'temp_{session_id}.json'
                with open(temp_file, 'w') as f:
                    json.dump({
                        'phone': phone,
                        'hash': result.phone_code_hash,
                        'session': client.session.save()
                    }, f)
                
                return {'success': True, 'session_id': session_id}
            except errors.FloodWaitError as e:
                return {'success': False, 'error': f'Too many attempts. Wait {e.seconds}s'}
            except Exception as e:
                return {'success': False, 'error': str(e)}
            finally:
                await client.disconnect()
        
        loop = asyncio.new_event_loop()
        result = loop.run_until_complete(send_code())
        loop.close()
        return jsonify(result)
        
    except Exception as e:
        logger.error(f"Add account error: {e}")
        return jsonify({'success': False, 'error': str(e)})

@app.route('/api/verify-code', methods=['POST'])
def verify_code():
    try:
        data = request.json
        code = data.get('code', '').strip()
        session_id = data.get('session_id', '')
        password = data.get('password', '')
        
        temp_file = f'temp_{session_id}.json'
        if not os.path.exists(temp_file):
            return jsonify({'success': False, 'error': 'Session expired'})
        
        with open(temp_file, 'r') as f:
            session_data = json.load(f)
        
        async def verify():
            client = TelegramClient(
                StringSession(session_data['session']),
                API_ID,
                API_HASH
            )
            try:
                await client.connect()
                
                # Sign in
                try:
                    await client.sign_in(
                        session_data['phone'],
                        code,
                        phone_code_hash=session_data['hash']
                    )
                except errors.SessionPasswordNeededError:
                    if not password:
                        return {'need_password': True}
                    await client.sign_in(password=password)
                
                me = await client.get_me()
                new_id = int(time.time() * 1000)
                
                new_account = {
                    'id': new_id,
                    'phone': me.phone or session_data['phone'],
                    'name': (me.first_name or '') + (' ' + me.last_name if me.last_name else ''),
                    'username': me.username or '',
                    'session': client.session.save(),
                    'active': True
                }
                
                accounts.append(new_account)
                save_json(ACCOUNTS_FILE, accounts)
                
                # Initialize settings
                auto_add_settings[str(new_id)] = {
                    'enabled': True,
                    'target_group': 'Abe_armygroup',
                    'delay_seconds': MIN_DELAY_SECONDS
                }
                save_json(SETTINGS_FILE, auto_add_settings)
                
                # Start auto-add
                start_auto_add(new_account)
                
                # Cleanup
                try:
                    os.remove(temp_file)
                except:
                    pass
                
                return {
                    'success': True,
                    'account': {
                        'id': new_id,
                        'name': new_account['name'],
                        'phone': new_account['phone']
                    }
                }
                
            except errors.PhoneCodeInvalidError:
                return {'success': False, 'error': 'Invalid code'}
            except errors.PhoneCodeExpiredError:
                return {'success': False, 'error': 'Code expired'}
            except Exception as e:
                return {'success': False, 'error': str(e)}
            finally:
                await client.disconnect()
        
        loop = asyncio.new_event_loop()
        result = loop.run_until_complete(verify())
        loop.close()
        return jsonify(result)
        
    except Exception as e:
        logger.error(f"Verify error: {e}")
        return jsonify({'success': False, 'error': str(e)})

@app.route('/api/remove-account', methods=['POST'])
def api_remove_account():
    aid = request.json.get('accountId')
    name = remove_account(aid, "Manual removal")
    return jsonify({'success': True, 'message': f'Removed: {name}'})

@app.route('/api/auto-add-settings', methods=['GET', 'POST'])
def auto_add_settings_route():
    if request.method == 'GET':
        aid = request.args.get('accountId')
        acc_key = str(aid)
        settings = auto_add_settings.get(acc_key, {
            'enabled': False,
            'target_group': 'Abe_armygroup',
            'delay_seconds': MIN_DELAY_SECONDS
        })
        
        today_adds = daily_adds[acc_key]['count'] if acc_key in daily_adds else 0
        
        return jsonify({
            'success': True,
            'settings': settings,
            'daily_stats': {
                'added_today': today_adds,
                'daily_limit': MAX_ADDS_PER_DAY,
                'remaining': max(0, MAX_ADDS_PER_DAY - today_adds),
                'min_delay': MIN_DELAY_SECONDS
            }
        })
    
    # POST
    data = request.json
    aid = data.get('accountId')
    acc_key = str(aid)
    
    auto_add_settings[acc_key] = {
        'enabled': data.get('enabled', False),
        'target_group': data.get('target_group', 'Abe_armygroup'),
        'delay_seconds': max(MIN_DELAY_SECONDS, data.get('delay_seconds', MIN_DELAY_SECONDS))
    }
    save_json(SETTINGS_FILE, auto_add_settings)
    
    # Start worker if enabled
    if data.get('enabled'):
        acc = next((a for a in accounts if a['id'] == aid), None)
        if acc:
            start_auto_add(acc)
    
    return jsonify({'success': True, 'message': 'Settings saved'})

@app.route('/api/stats')
def get_stats():
    today = datetime.now().strftime('%Y-%m-%d')
    if stats['last_reset'] != today:
        stats['today_added'] = 0
        stats['last_reset'] = today
    
    return jsonify({
        'success': True,
        'stats': stats,
        'rate_limits': {
            'max_per_day': MAX_ADDS_PER_DAY,
            'min_delay_seconds': MIN_DELAY_SECONDS
        }
    })

# ============================================
# STARTUP & KEEPALIVE
# ============================================
def keep_alive():
    """Keep the server alive with self-pings"""
    while True:
        time.sleep(240)
        try:
            requests.get(f"{SERVER_URL}/ping", timeout=10)
        except:
            pass

def restore_and_start():
    """Restore accounts and start workers on boot"""
    time.sleep(5)
    
    for acc in accounts:
        if acc.get('session'):
            # Try to verify account is still valid
            try:
                client = get_client(acc)
                loop = asyncio.new_event_loop()
                
                async def check():
                    await client.connect()
                    try:
                        return await client.is_user_authorized()
                    finally:
                        await client.disconnect()
                
                authorized = loop.run_until_complete(check())
                loop.close()
                
                if authorized:
                    start_auto_add(acc)
                    time.sleep(2)
                else:
                    remove_account(acc['id'], "Not authorized on restart")
            except:
                remove_account(acc['id'], "Failed startup check")
    
    logger.info(f"Server {SERVER_NAME} started with {len(accounts)} accounts")
    logger.info(f"Rate limits: {MAX_ADDS_PER_DAY} adds/day, {MIN_DELAY_SECONDS}s delay")

# ============================================
# MAIN
# ============================================
if __name__ == '__main__':
    # Load saved data
    accounts = load_json(ACCOUNTS_FILE, [])
    auto_add_settings = load_json(SETTINGS_FILE, {})
    stats = load_json(STATS_FILE, stats)
    daily_adds.update(load_json(DAILY_ADDS_FILE, {}))
    
    print(f"""
╔══════════════════════════════════════════╗
║  SAFE AUTO-ADD SERVER #{SERVER_NUMBER}              ║
║  Name: {SERVER_NAME}                         ║
║  Max: {MAX_ADDS_PER_DAY} adds/day                   ║
║  Delay: {MIN_DELAY_SECONDS}s between adds            ║
║  Port: {PORT}                               ║
║  Features:                              ║
║  - Rate limiting (120/day)             ║
║  - Anti-spam delays (60s)              ║
║  - Flood protection                    ║
║  - Crash recovery                      ║
╚══════════════════════════════════════════╝
    """)
    
    # Start background threads
    threading.Thread(target=keep_alive, daemon=True).start()
    threading.Thread(target=restore_and_start, daemon=True).start()
    
    # Run Flask
    app.run(host='0.0.0.0', port=PORT, debug=False)
