const { InstanceBase, Regex, runEntrypoint, InstanceStatus } = require('@companion-module/base')

class C200ControllerInstance extends InstanceBase {
    constructor(internal) {
        super(internal)
    }

    async init(config) {
        this.config = config
        this.updateStatus(InstanceStatus.Connecting)

        this.initActions()
        this.initFeedbacks()
        this.initVariables()
        this.initPresets()

        if (this.config.host) {
            this.connect()
        } else {
            this.updateStatus(InstanceStatus.BadConfig)
        }
    }

    async destroy() {
        if (this.pollInterval) {
            clearInterval(this.pollInterval)
        }
        this.log('debug', 'Module destroyed')
    }

    async configUpdated(config) {
        this.config = config
        this.connect()
    }

    getConfigFields() {
        return [
            {
                type: 'textinput',
                id: 'host',
                label: 'ESP32 IP Address',
                width: 8,
                regex: Regex.IP,
                default: '',
            },
            {
                type: 'number',
                id: 'pollInterval',
                label: 'Poll Interval (ms)',
                width: 4,
                min: 500,
                max: 10000,
                default: 2000,
            },
        ]
    }

    async connect() {
        if (!this.config.host) {
            this.updateStatus(InstanceStatus.BadConfig)
            return
        }

        try {
            const response = await this.request('/api/status')
            if (response) {
                this.updateStatus(InstanceStatus.Ok)
                this.startPolling()
            }
        } catch (error) {
            this.updateStatus(InstanceStatus.ConnectionFailure)
            this.log('error', `Connection failed: ${error.message}`)
        }
    }

    async request(path, method = 'GET') {
        const url = `http://${this.config.host}${path}`

        try {
            const controller = new AbortController()
            const timeout = setTimeout(() => controller.abort(), 5000)

            const response = await fetch(url, {
                method,
                signal: controller.signal,
            })

            clearTimeout(timeout)

            if (response.ok) {
                return await response.json()
            }
        } catch (error) {
            if (error.name === 'AbortError') {
                throw new Error('Request timeout')
            }
            throw error
        }
        return null
    }

    startPolling() {
        if (this.pollInterval) {
            clearInterval(this.pollInterval)
        }

        this.poll()
        this.pollInterval = setInterval(() => this.poll(), this.config.pollInterval || 2000)
    }

    async poll() {
        try {
            // Get status
            const status = await this.request('/api/status')
            if (status) {
                this.setVariableValues({
                    wifi_connected: status.wifi_connected ? 'Yes' : 'No',
                    eth_connected: status.eth_connected ? 'Yes' : 'No',
                    camera_connected: status.camera_connected ? 'Yes' : 'No',
                    wifi_ip: status.wifi_ip || '--',
                    eth_ip: status.eth_ip || '--',
                    camera_ip: status.camera_ip || '--',
                })
            }

            // Get camera state
            const state = await this.request('/api/camera/state')
            if (state) {
                this.setVariableValues({
                    aperture: state.av?.value || '--',
                    iso: state.gcv?.value || '--',
                    shutter: state.ssv?.value || '--',
                    ae_shift: state.aesv?.value || '--',
                    nd_filter: state.ndv?.value || '--',
                    wb_mode: state.wbm?.value || '--',
                    wb_kelvin: state.wbvk?.value ? `${state.wbvk.value}K` : '--',
                    af_mode: state.afm?.value || '--',
                    face_detect: state.fdat?.value || '--',
                })
            }

            this.checkFeedbacks('camera_connected', 'recording')
        } catch (error) {
            this.log('debug', `Poll error: ${error.message}`)
        }
    }

    async sendCommand(control, direction) {
        try {
            await this.request(`/api/camera/${control}/${direction}`, 'POST')
            // Trigger a poll to update variables
            setTimeout(() => this.poll(), 500)
        } catch (error) {
            this.log('error', `Command failed: ${error.message}`)
        }
    }

    initActions() {
        this.setActionDefinitions({
            // Recording
            toggle_record: {
                name: 'Toggle Recording',
                options: [],
                callback: async () => {
                    await this.request('/api/camera/rec', 'POST')
                },
            },

            // Iris
            iris_up: {
                name: 'Iris Up (Open)',
                options: [],
                callback: async () => {
                    await this.sendCommand('iris', 'plus')
                },
            },
            iris_down: {
                name: 'Iris Down (Close)',
                options: [],
                callback: async () => {
                    await this.sendCommand('iris', 'minus')
                },
            },

            // ISO
            iso_up: {
                name: 'ISO Up',
                options: [],
                callback: async () => {
                    await this.sendCommand('iso', 'plus')
                },
            },
            iso_down: {
                name: 'ISO Down',
                options: [],
                callback: async () => {
                    await this.sendCommand('iso', 'minus')
                },
            },

            // Shutter
            shutter_up: {
                name: 'Shutter Up (Faster)',
                options: [],
                callback: async () => {
                    await this.sendCommand('shutter', 'plus')
                },
            },
            shutter_down: {
                name: 'Shutter Down (Slower)',
                options: [],
                callback: async () => {
                    await this.sendCommand('shutter', 'minus')
                },
            },

            // ND Filter
            nd_up: {
                name: 'ND Filter Up (More)',
                options: [],
                callback: async () => {
                    await this.sendCommand('nd', 'plus')
                },
            },
            nd_down: {
                name: 'ND Filter Down (Less)',
                options: [],
                callback: async () => {
                    await this.sendCommand('nd', 'minus')
                },
            },

            // AE Shift
            ae_shift_up: {
                name: 'AE Shift Up',
                options: [],
                callback: async () => {
                    await this.sendCommand('aes', 'plus')
                },
            },
            ae_shift_down: {
                name: 'AE Shift Down',
                options: [],
                callback: async () => {
                    await this.sendCommand('aes', 'minus')
                },
            },

            // White Balance
            set_wb: {
                name: 'Set White Balance',
                options: [
                    {
                        type: 'dropdown',
                        id: 'mode',
                        label: 'White Balance Mode',
                        default: 'awb',
                        choices: [
                            { id: 'awb', label: 'Auto White Balance' },
                            { id: 'daylight', label: 'Daylight' },
                            { id: 'tungsten', label: 'Tungsten' },
                            { id: 'user1', label: 'User 1' },
                            { id: 'user2', label: 'User 2' },
                            { id: 'seta', label: 'Set A' },
                            { id: 'setb', label: 'Set B' },
                        ],
                    },
                ],
                callback: async (action) => {
                    await this.request(`/api/camera/wb/${action.options.mode}`, 'POST')
                    setTimeout(() => this.poll(), 500)
                },
            },

            // Focus
            focus_oneshot: {
                name: 'One-Shot AF',
                options: [],
                callback: async () => {
                    await this.request('/api/camera/focus/oneshot', 'POST')
                },
            },
            focus_lock: {
                name: 'AF Lock',
                options: [],
                callback: async () => {
                    await this.request('/api/camera/focus/lock', 'POST')
                },
            },
            focus_track: {
                name: 'Face/Subject Track',
                options: [],
                callback: async () => {
                    await this.request('/api/camera/focus/track', 'POST')
                },
            },
            focus_near: {
                name: 'Manual Focus Near',
                options: [
                    {
                        type: 'dropdown',
                        id: 'speed',
                        label: 'Speed',
                        default: 'near1',
                        choices: [
                            { id: 'near1', label: 'Slow' },
                            { id: 'near2', label: 'Medium' },
                            { id: 'near3', label: 'Fast' },
                        ],
                    },
                ],
                callback: async (action) => {
                    await this.request(`/api/camera/focus/${action.options.speed}`, 'POST')
                },
            },
            focus_far: {
                name: 'Manual Focus Far',
                options: [
                    {
                        type: 'dropdown',
                        id: 'speed',
                        label: 'Speed',
                        default: 'far1',
                        choices: [
                            { id: 'far1', label: 'Slow' },
                            { id: 'far2', label: 'Medium' },
                            { id: 'far3', label: 'Fast' },
                        ],
                    },
                ],
                callback: async (action) => {
                    await this.request(`/api/camera/focus/${action.options.speed}`, 'POST')
                },
            },
        })
    }

    initFeedbacks() {
        this.setFeedbackDefinitions({
            camera_connected: {
                type: 'boolean',
                name: 'Camera Connected',
                description: 'Changes when camera is connected/disconnected',
                defaultStyle: {
                    bgcolor: 0x00ff00,
                    color: 0x000000,
                },
                options: [],
                callback: () => {
                    return this.getVariableValue('camera_connected') === 'Yes'
                },
            },
        })
    }

    initVariables() {
        this.setVariableDefinitions([
            // Connection status
            { variableId: 'wifi_connected', name: 'WiFi Connected' },
            { variableId: 'eth_connected', name: 'Ethernet Connected' },
            { variableId: 'camera_connected', name: 'Camera Connected' },
            { variableId: 'wifi_ip', name: 'WiFi IP Address' },
            { variableId: 'eth_ip', name: 'Ethernet IP Address' },
            { variableId: 'camera_ip', name: 'Camera IP Address' },

            // Camera settings
            { variableId: 'aperture', name: 'Aperture' },
            { variableId: 'iso', name: 'ISO' },
            { variableId: 'shutter', name: 'Shutter' },
            { variableId: 'ae_shift', name: 'AE Shift' },
            { variableId: 'nd_filter', name: 'ND Filter' },
            { variableId: 'wb_mode', name: 'White Balance Mode' },
            { variableId: 'wb_kelvin', name: 'White Balance Kelvin' },
            { variableId: 'af_mode', name: 'AF Mode' },
            { variableId: 'face_detect', name: 'Face Detection' },
        ])
    }

    initPresets() {
        this.setPresetDefinitions({
            // Recording
            toggle_record: {
                type: 'button',
                category: 'Recording',
                name: 'Toggle Record',
                style: {
                    text: 'REC',
                    size: '18',
                    color: 0xffffff,
                    bgcolor: 0xff0000,
                },
                steps: [
                    {
                        down: [{ actionId: 'toggle_record' }],
                    },
                ],
            },

            // Exposure presets
            iris_up: {
                type: 'button',
                category: 'Exposure',
                name: 'Iris +',
                style: {
                    text: 'IRIS\\n+',
                    size: '14',
                    color: 0xffffff,
                    bgcolor: 0x333333,
                },
                steps: [{ down: [{ actionId: 'iris_up' }] }],
            },
            iris_down: {
                type: 'button',
                category: 'Exposure',
                name: 'Iris -',
                style: {
                    text: 'IRIS\\n-',
                    size: '14',
                    color: 0xffffff,
                    bgcolor: 0x333333,
                },
                steps: [{ down: [{ actionId: 'iris_down' }] }],
            },
            iso_up: {
                type: 'button',
                category: 'Exposure',
                name: 'ISO +',
                style: {
                    text: 'ISO\\n+',
                    size: '14',
                    color: 0xffffff,
                    bgcolor: 0x333333,
                },
                steps: [{ down: [{ actionId: 'iso_up' }] }],
            },
            iso_down: {
                type: 'button',
                category: 'Exposure',
                name: 'ISO -',
                style: {
                    text: 'ISO\\n-',
                    size: '14',
                    color: 0xffffff,
                    bgcolor: 0x333333,
                },
                steps: [{ down: [{ actionId: 'iso_down' }] }],
            },

            // ND presets
            nd_up: {
                type: 'button',
                category: 'ND Filter',
                name: 'ND +',
                style: {
                    text: 'ND\\n+',
                    size: '14',
                    color: 0xffffff,
                    bgcolor: 0x666633,
                },
                steps: [{ down: [{ actionId: 'nd_up' }] }],
            },
            nd_down: {
                type: 'button',
                category: 'ND Filter',
                name: 'ND -',
                style: {
                    text: 'ND\\n-',
                    size: '14',
                    color: 0xffffff,
                    bgcolor: 0x666633,
                },
                steps: [{ down: [{ actionId: 'nd_down' }] }],
            },

            // White Balance presets
            wb_awb: {
                type: 'button',
                category: 'White Balance',
                name: 'AWB',
                style: {
                    text: 'AWB',
                    size: '14',
                    color: 0xffffff,
                    bgcolor: 0x336699,
                },
                steps: [
                    {
                        down: [
                            {
                                actionId: 'set_wb',
                                options: { mode: 'awb' },
                            },
                        ],
                    },
                ],
            },
            wb_daylight: {
                type: 'button',
                category: 'White Balance',
                name: 'Daylight',
                style: {
                    text: 'DAY',
                    size: '14',
                    color: 0xffffff,
                    bgcolor: 0xff9933,
                },
                steps: [
                    {
                        down: [
                            {
                                actionId: 'set_wb',
                                options: { mode: 'daylight' },
                            },
                        ],
                    },
                ],
            },
            wb_tungsten: {
                type: 'button',
                category: 'White Balance',
                name: 'Tungsten',
                style: {
                    text: 'TUNG',
                    size: '14',
                    color: 0xffffff,
                    bgcolor: 0xff6600,
                },
                steps: [
                    {
                        down: [
                            {
                                actionId: 'set_wb',
                                options: { mode: 'tungsten' },
                            },
                        ],
                    },
                ],
            },

            // Focus presets
            focus_oneshot: {
                type: 'button',
                category: 'Focus',
                name: 'One-Shot AF',
                style: {
                    text: 'AF\\nONE',
                    size: '14',
                    color: 0xffffff,
                    bgcolor: 0x006633,
                },
                steps: [{ down: [{ actionId: 'focus_oneshot' }] }],
            },
        })
    }
}

runEntrypoint(C200ControllerInstance, [])
